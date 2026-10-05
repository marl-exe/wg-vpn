# Client bypass review

Reviewed draft PR #1 from commit `9d8d7ead5432a61f34675f6076c228c27476d166` on 2026-10-05. Scope: the two optional client helpers, documentation and tests. No installer/server module, WireGuard configuration, keys, firewall, NAT, server route or mobile implementation was changed.

## Important findings and fixes

1. **High: Windows trusted writable state for elevated route deletion.** State now requires Administrators/SYSTEM ownership/access, rejects reparse points, and is serialized by an exclusive file lock. Atomic file replacement avoids partial JSON/domain writes. Unsafe legacy state is rejected, not silently adopted.
2. **High: Linux state and lock paths followed links.** Root-owned private state replaces world-readable state and the shared `/run/lock` path. Symlinks, hardlinks, non-root ownership and writable-by-others paths are rejected before opening files. The lock is inside the protected directory and is not unlinked.
3. **High: cleanup ownership was too weak.** Windows previously deleted every same-prefix/gateway/interface match, including replacements after reboot. Linux matched substrings across multiple output lines and omitted the metric from deletion. Cleanup now checks a randomized metric, exact attributes on one route, protocol, and boot state; Windows additionally checks interface GUID. Existing host routes are skipped on all interfaces. No protocol-wide or prefix-only sweep is used.
4. **High: failed deletions and interrupted batches lost tracking.** Both retain failed deletion entries, stop reset/refresh if cleanup fails, and record each successful route immediately. Windows state parsing now fails closed, and JSON arrays work under PowerShell 5.1. The unavoidable route-add/state-save interruption window remains documented.
5. **Medium: removing the last domain left its routes active.** Empty-list refresh now invokes cleanup on both platforms. Windows saves an explicitly empty domain file rather than sending an empty pipeline into `Set-Content`.
6. **Medium: DNS failures silently erased working routes.** Resolution is staged before cleanup; a hostname with no usable results stops refresh with an actionable error and retains existing routes. Address validation rejects malformed/unsafe results and IPv4-mapped IPv6 results. Per-family incomplete answers remain a limitation.
7. **Medium: elevation argument transport was fragile.** Windows now encodes a JSON data payload, invokes it without evaluating input as source, preserves the current runtime, and waits for the child exit code. Linux resolves the script path and uses `/bin/bash -- <path>` with an argument array, including paths with spaces; it uses a fixed system command search path. Neither helper uses `eval`. Only run trusted downloaded scripts; no elevation wrapper can make an attacker-writable script safe to execute as administrator/root.
8. **Medium: gateway discovery could choose other tunnels or dead routes.** Both now select connected physical/VM interfaces conservatively. Linux rejects dead/linkdown, multipath and source-specific defaults; route metrics are parsed as decimal. Missing Windows adapters no longer cause StrictMode property errors. Bridges/PPP/ambiguous virtual uplinks are unsupported rather than guessed.
9. **Medium: Windows wildcard support was incomplete and presets differed.** Both now reject wildcards and use the same narrow exact-hostname preset. No generic third-party shared-service domains were added. IP routes can still bypass unrelated sites sharing a CDN address.
10. **Low: Linux declining a menu confirmation could exit under `set -e`.** Confirmation branches now use explicit `if` statements. Documentation explains reboot/reconnect behavior, failed refresh/removal, conservative gateway support and tracked-vs-live status.

## Routing conclusions

**Windows:** the split `/1` pairs cover the entire respective address spaces and allow more-specific host routes. Upstream explicitly documents that they avoid its single-peer `/0` kill switch. The manual change also removes its special DNS restrictions and tunnel-down protection. The helper conservatively detects `/0` routes and refuses refresh; it never edits client configuration. This is reasonable for an intentional bypass utility, not a leak-proof security boundary. Real Windows 10/11 WireGuard traffic and UAC interaction still require operator testing; offline tests do not prove connectivity.

**Linux:** verified against upstream `wg-quick` implementation and documentation: `lookup main suppress_prefixlength 0` precedes the unmarked-packet tunnel-table lookup. Main-table `/32` and `/128` routes therefore work without changing `/0` AllowedIPs. The namespace regression test checks both families, unchanged destinations, marked outer-packet behavior and cleanup using that exact policy layout. It models the tunnel with a dummy link, not a live WireGuard session. Other policy rules, firewall kill switches, proxies and network namespaces can invalidate the assumptions.

**Can cleanup ever remove an uncreated route?** Pre-existing routes are skipped, and changed ownership attributes prevent deletion. An absolute "never" guarantee is not possible: an administrator can replace a route with identical attributes between inspection and deletion or while state remains saved. No immutable route creator identifier or atomic compare-and-delete transaction is available here. This residual privileged-race/identical-replacement risk is explicitly documented rather than hidden behind a protocol number.

## Verification

- Native Windows PowerShell 5.1: parser and offline regressions passed, including elevation data transport, empty domain cleanup, failed deletion retention, stale boot metadata, non-host prefix rejection and DNS failure preservation.
- Git Bash: `bash -n` and offline Linux fixtures passed. These are not native Linux networking tests.
- Local PowerShell 7, WSL/Linux and PSScriptAnalyzer are unavailable. No host packages were installed.
- CI includes native PowerShell 5.1/7 checks, Bash syntax, ShellCheck, offline fixtures, existing server safety tests and isolated Linux kernel routing tests. CI outcomes are reported separately after the branch is pushed.
- No production/workstation route changes or live VPN connectivity tests were performed. No application build is applicable to standalone interpreted helpers.

Primary references: [WireGuard Windows networking](https://git.zx2c4.com/wireguard-windows/about/docs/netquirk.md), [WireGuard policy routing](https://www.wireguard.com/netns/#improved-rule-based-routing), [wg-quick Linux source](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash), [Microsoft New-NetRoute](https://learn.microsoft.com/en-us/powershell/module/nettcpip/new-netroute).
