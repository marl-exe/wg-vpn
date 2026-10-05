# wg-vpn

Lightweight, low-latency WireGuard VPN installer and CLI manager for Ubuntu/Debian VPSes.

`wg-vpn` is designed for VPSes that already run other workloads. It installs native WireGuard, makes narrowly scoped networking changes, and provides a CLI manager without requiring Docker, Node.js, Python, a database, a Web UI, or an always-running management daemon.

The current V1 has been successfully tested on real Ubuntu VPSes running Ubuntu 24.04.4 LTS (Noble Numbat) and Ubuntu 26.04.1 LTS (Resolute Raccoon), including both directly addressed VPSes and a real NAT/shared-IPv4 VPS. Testing has covered clean installation, first-client creation and QR generation, full-tunnel routing, live handshakes, bidirectional traffic transfer, client management, iptables-nft integration, automatic MTU behavior, NAT endpoint-port handling, and an older-install upgrade/uninstall/fresh-install cycle.

## Design goals

- Native kernel WireGuard where supported
- Zero management CPU/RAM while the CLI is not running
- Safe coexistence with Docker, websites, bots, game servers, RDP, and monitoring
- Dedicated VPN subnet (default `10.66.66.0/24`)
- Automatic public-interface and public-endpoint detection
- NAT/shared-IPv4 VPS detection, including CGNAT source addresses
- Separate public endpoint and internal WireGuard UDP ports for provider port forwarding
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

If the VPS source address is private or CGNAT, automatic mode identifies it as a NAT/port-forwarded environment and asks for one public UDP port assigned by the VPS provider. Automatic mode uses that same port for the local WireGuard listener, matching the common 1:1 forwarding model. Providers that map a public port to a different internal port are supported through Manual / Advanced mode.

Manual / Advanced mode lets you override:

- Public network interface
- Public IP or DNS endpoint
- Public endpoint UDP port
- Internal WireGuard UDP port
- WireGuard interface name
- VPN subnet
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

## NAT / shared IPv4 VPSes

`wg-vpn` separates the public client-facing endpoint port from the UDP port WireGuard listens on locally:

```text
WG_PORT=51820
ENDPOINT_PORT=32451
```

The server continues to listen and firewall locally on `WG_PORT`, while generated client configurations use:

```ini
Endpoint = <public-ip-or-hostname>:32451
```

Automatic mode is optimized for the common 1:1 provider mapping:

```text
public :32451 -> private :32451
```

If a provider instead maps a public port to a different internal port, Manual / Advanced mode supports that configuration:

```text
public :32451 -> private :51820
```

For NAT VPS plans that allocate a small pool of random forwarded ports, only one UDP-capable forwarded port is required. The installer does not attempt to guess provider-assigned ports; the user enters one of the ports allocated by the provider.

This flow has been successfully runtime-tested on a real shared-IPv4 VPS with a private `192.168.x.x` source address and a provider-assigned block of 20 TCP/UDP ports using 1:1 public-to-private port forwarding. Automatic NAT detection identified the private source address, the selected provider port was used for both the public endpoint and local WireGuard listener, and a client completed a working WireGuard connection through the forwarded UDP port.

Existing configurations created before `ENDPOINT_PORT` was introduced remain compatible. If the setting is absent, `wg-vpn` treats the public endpoint port as the existing `WG_PORT`.

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

The current `0.4.x` line builds on the runtime-tested `0.3.x` networking path and has completed real-world runtime testing on multiple Ubuntu VPSes running Ubuntu 24.04.4 LTS (Noble Numbat) and Ubuntu 26.04.1 LTS (Resolute Raccoon). Verified behavior includes:

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
- NAT/shared-IPv4 detection from a private `192.168.x.x` source address
- Provider-assigned forwarded UDP port selection
- Real 1:1 NAT port mapping with successful client connectivity

The repository also passes Bash syntax checks, ShellCheck, and safety regression tests covering strict metadata parsing, hostile/duplicate archive entries, IPv4/IPv6 CIDR validation, DNS/endpoint validation, firewall-flush guards, whole-`/etc/wireguard` deletion guards, lock-file preservation, installer prompt regressions, first-client default inheritance, and staged WireGuard validation behavior.

Fresh installation and normal client creation are runtime-validated on both directly addressed VPSes and a real NAT/shared-IPv4 VPS using provider-forwarded UDP ports. NAT endpoint-port behavior is also covered by repository regression tests. Broader runtime testing is still desirable for non-1:1 NAT mappings where the public endpoint port differs from the internal WireGuard listen port, IPv6 deployments, backup/restore under failure conditions, rollback verification, unusual firewall layouts, containerized VPS environments, and other edge-case host configurations.


## Optional client-side domain bypass

The optional client-side bypass feature lives under `desktop/`, keeping desktop/client routing helpers separate from the server-side installer and CLI. It is for users who need selected domains to use the device's normal Internet connection while the rest of their traffic continues through a full-tunnel VPN:

- `desktop/wg-vpn-bypass.ps1` — Windows 10/11
- `desktop/wg-vpn-bypass.sh` — Linux clients using `iproute2` (targeted at Ubuntu/Debian)

These helpers change routing only on the client device where they are run. They do **not** modify the VPS, WireGuard server, peer keys, server firewall/NAT rules, or the wg-vpn server installation.

The helpers are optional. Normal wg-vpn users do not need them.

### Windows

Run the Windows helper from PowerShell:

```powershell
.\desktop\wg-vpn-bypass.ps1
```

It requests Administrator elevation when needed. The interactive menu can add/remove domains, install the ChatGPT/OpenAI preset, refresh DNS-derived routes, show status, clear active bypass routes, or reset the helper.

Command-line use is also supported:

```powershell
.\desktop\wg-vpn-bypass.ps1 add chatgpt.com
.\desktop\wg-vpn-bypass.ps1 add-chatgpt
.\desktop\wg-vpn-bypass.ps1 list
.\desktop\wg-vpn-bypass.ps1 refresh
.\desktop\wg-vpn-bypass.ps1 status
.\desktop\wg-vpn-bypass.ps1 remove chatgpt.com
.\desktop\wg-vpn-bypass.ps1 clear
.\desktop\wg-vpn-bypass.ps1 reset
```

#### Required WireGuard for Windows `AllowedIPs` change

WireGuard for Windows applies special block-untunneled-traffic / kill-switch behavior when an interface has one peer and that peer contains a `/0` AllowedIP. The helper conservatively refuses any detected WireGuard `/0` route; it does not inspect peer configuration. A route-only bypass requires the equivalent pair of `/1` routes instead.

For the recommended Windows bypass setup, use IPv4 split-default routes.

If the client currently has:

```ini
AllowedIPs = 0.0.0.0/0
```

change it to:

```ini
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
```

If the client currently has:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

use the same IPv4-only bypass configuration:

```ini
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
```

This keeps IPv4 effectively full-tunnel while allowing more-specific IPv4 bypass routes. It also avoids sending IPv6 destinations through the VPN on clients that do not have a usable physical IPv6 gateway.

Only add `::/1, 8000::/1` if the client has confirmed native IPv6 connectivity outside WireGuard and you intentionally want IPv6 full-tunnel routing. The bypass helper can create IPv6 host routes only when it detects a usable physical IPv6 gateway; otherwise IPv6 destinations would remain inside the VPN and can defeat the intended domain bypass.

The IPv4 `/1` pair still covers the complete IPv4 address space, but it does not activate WireGuard for Windows' special `/0` kill-switch behavior. Windows can therefore select a more-specific bypass route.

**Important:** replacing `/0` also removes that WireGuard-specific kill-switch behavior. If the tunnel goes down, Windows may use the normal network connection.

Make this change **manually in the client configuration**, then deactivate/reactivate the tunnel. The helper never edits WireGuard configuration. The change also removes WireGuard's special DNS firewall restrictions; ordinary Windows multihomed DNS behavior applies. An independent VPN/firewall kill switch can still prevent bypass. See [WireGuard's Windows networking documentation](https://git.zx2c4.com/wireguard-windows/about/docs/netquirk.md).

The Windows helper stores its domain list and route metadata under `%ProgramData%\WG-VPN-Bypass`. Its routes use Windows `ActiveStore`, so they are temporary and disappear after reboot.

State is restricted to Administrators/SYSTEM and concurrent runs are locked. Unsafe permissions or linked state paths cause an error instead of being silently trusted. If upgrading from the original draft helper, reboot to expire its temporary routes, archive the old state directory as Administrator, and re-add exact hostnames in a fresh directory. Do not import old `routes.json`; it lacks the new ownership fields. PowerShell 5.1 and 7 are supported on Windows 10/11. Elevation preserves the current PowerShell runtime and passes arguments as encoded data.

### Linux

Run the Linux helper with root privileges:

```bash
chmod +x desktop/wg-vpn-bypass.sh
sudo ./desktop/wg-vpn-bypass.sh
```

Command-line use mirrors the Windows helper:

```bash
sudo ./desktop/wg-vpn-bypass.sh add chatgpt.com
sudo ./desktop/wg-vpn-bypass.sh add-chatgpt
sudo ./desktop/wg-vpn-bypass.sh list
sudo ./desktop/wg-vpn-bypass.sh refresh
sudo ./desktop/wg-vpn-bypass.sh status
sudo ./desktop/wg-vpn-bypass.sh remove chatgpt.com
sudo ./desktop/wg-vpn-bypass.sh clear
sudo ./desktop/wg-vpn-bypass.sh reset
```

On Linux, the helper does **not** require changing `AllowedIPs = 0.0.0.0/0`. Normal `wg-quick` full-tunnel routing uses Linux policy routing, and a more-specific host route in the main routing table can send a selected destination through the normal non-WireGuard gateway.

Specifically, `wg-quick` installs a `lookup main suppress_prefixlength 0` rule ahead of its `not fwmark ... lookup ...` tunnel rule. The first rule accepts `/32` and `/128` main-table routes and suppresses only the default route. Other destinations then reach the tunnel table; WireGuard's marked outer packets skip that table and can use the normal default. This applies independently to IPv4 and IPv6. See [the upstream policy-routing explanation](https://www.wireguard.com/netns/#improved-rule-based-routing) and [wg-quick source](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash).

Custom policy rules, other VPNs, network namespaces, NetworkManager-specific tunnel policies, and firewall kill switches may behave differently. The helper never changes those rules or firewalls. Detecting a gateway does not prove Internet reachability or that a firewall will permit traffic.

The Linux helper:

- finds a non-WireGuard IPv4/IPv6 default route in the main routing table
- resolves configured hostnames to current A/AAAA addresses
- adds `/32` IPv4 and `/128` IPv6 routes through that normal gateway
- tags routes it creates with a dedicated route protocol number and tracks them in its own state
- skips pre-existing host routes and scopes cleanup to saved ownership attributes (see limits below)
- stores state under `/var/lib/wg-vpn-bypass`

The Linux state directory is root-owned mode `0700`, with `0600` files and a lock inside that directory. Symlinks, hardlinked state files, and non-root/group-writable state are rejected. Temporary routes disappear on reboot; saved hostnames remain, and old-boot route metadata is discarded without deleting routes. Upgrading from the original draft requires a reboot to expire old routes whose ownership cannot safely be migrated. No startup service is installed.

Gateway selection uses connected physical/VM Ethernet or Wi-Fi interfaces and route metrics, separately for each address family. With both Ethernet and Wi-Fi it chooses the lowest metric (Windows includes the interface metric). Linux supports gatewayless physical defaults. Bridges, PPP, virtual-only uplinks, multipath/source-specific defaults and unusual VPN adapters are intentionally not automatically selected. NetworkManager/systemd-networkd physical defaults in `main` are supported; automatic reapplication after DHCP, roaming, reconnect or DNS changes is not provided. Run `refresh` after those changes. Windows requires a nonzero next-hop gateway.

Wildcard domain entries are intentionally unsupported on **both platforms**. A DNS-cache snapshot cannot enumerate every hostname under `*.example.com`, and browser encrypted DNS may bypass the OS cache altogether. Add exact hostnames instead, or use the built-in ChatGPT/OpenAI preset.

### DNS and shared-IP limitations

Both helpers implement bypasses with IP routes because operating-system routing is IP-based, not hostname-based.

A hostname may resolve to multiple addresses, and those addresses can change. Run `refresh` when a service's DNS addresses change. Shared CDN/IP addresses may also serve other hostnames, so bypassing one destination IP can cause other traffic using that same IP to follow the normal connection.

The built-in ChatGPT/OpenAI preset is therefore intentionally conservative rather than automatically bypassing broad third-party infrastructure.

Both presets contain the same exact hostnames: `chatgpt.com`, `openai.com`, `auth.openai.com`, `auth0.openai.com`, `chat.openai.com`, `setup.auth.openai.com`, and `cdn.openaimerge.com`. This is a starting list, not a guarantee that every login, upload, voice or static-content endpoint bypasses the VPN. `desktop.chat.openai.com` is intentionally not included because it may have no usable DNS answer on browser-only clients; add it manually only if your environment needs it and it resolves. Add other individual hostnames as needed; no generic Cloudflare, Stripe, Intercom, WorkOS, Apple or Sentry domains are included.

Refresh resolves all configured names before clearing existing routes. If a name has no usable addresses, it reports the failure and keeps existing routes; remove obsolete names or fix DNS and retry. A/AAAA resolution can still be partially successful: a missing family is not proof that the domain never uses it. Linux `getent` uses the host's NSS/address-family configuration and excludes IPv4-mapped IPv6 results. Neither helper monitors TTLs, changes DNS servers, or guarantees that browser/proxy DNS sees the same addresses. Close/reopen existing connections when testing routing changes. A successful route add is not an end-to-end application connectivity test.

`clear` removes tracked active routes but keeps the domain list. Removing the last hostname also clears tracked routes. `reset` clears both, but stops if cleanup fails. Failed route deletions retain state for a retry. If refresh fails after you remove a hostname, use `clear` to remove remaining bypasses before retrying.

#### Route ownership limits

Cleanup requires saved host-prefix, gateway, interface and randomized metric to match. Linux additionally requires numeric protocol `186`; Windows requires `NetMgmt`, the original interface GUID and the current boot identity. State files are data, never executable code. Pre-existing host routes are neither adopted nor replaced. Status reports **tracked metadata**, which may outlive a route after reconnect or external changes.

These checks are not an immutable ownership token: route APIs cannot distinguish a privileged actor deleting a helper route and recreating one with identical attributes in the same boot. Therefore an absolute promise that cleanup can *never* remove somebody else's identical replacement is impossible with this design. Do not reuse the helper's full route attributes or edit its state. Forced termination/power loss between successful route creation and saving state can leave an untracked temporary route; it is deliberately not swept by destination or protocol alone. Reboot expires such routes. This small interruption window remains; there is no daemon or transactional route API.

#### Client-helper tests

No Docker or additional application runtime is required:

```powershell
powershell.exe -NoProfile -File tests\desktop\bypass.ps1
pwsh -NoProfile -File tests\desktop\bypass.ps1
```

```bash
bash -n desktop/wg-vpn-bypass.sh
bash tests/bypass.sh
shellcheck --severity=error -e SC1090,SC1091 desktop/wg-vpn-bypass.sh tests/desktop/bypass*.sh
# Linux test runner only: isolated namespace, no host route/firewall changes
sudo bash tests/bypass-netns.sh
```

CI runs both Windows runtimes and Linux fixtures plus kernel IPv4/IPv6 route lookups using the same policy rules as `wg-quick`. The namespace test models its tunnel table with a dummy link; it does not test encrypted traffic or launch an actual WireGuard tunnel. See [the review report](BYPASS-REVIEW.md) for findings and verification scope.

### Mobile clients

Domain-based bypass is **not supported by these helpers on Android or iOS**.

Android's VPN APIs and some WireGuard clients can support app-level inclusion/exclusion, but that is different from selectively bypassing individual domains. Reliable domain-based bypass on Android would require a different client-side design (or root/custom VPN handling).

iOS is more restricted and does not provide a comparable general-purpose shell/routing mechanism for this project.

For V1, the optional domain-bypass helpers are intentionally limited to Windows and Linux desktop/server clients.

## License

MIT
