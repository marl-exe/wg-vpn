<#
.SYNOPSIS
    Windows-only domain bypass helper for full-tunnel WireGuard/VPN clients.

.DESCRIPTION
    Resolves selected domains and adds temporary host routes through the
    normal Windows gateway instead of the VPN tunnel.

    This script changes only the Windows PC where it is run. It does not
    modify the WireGuard server, VPS, peer keys, or server configuration.

    For WireGuard for Windows, a peer using 0.0.0.0/0 or ::/0 normally
    enables block-untunneled-traffic (kill-switch) behavior. For this helper,
    use the equivalent split default routes instead:

      IPv4:
        0.0.0.0/1, 128.0.0.0/1

      IPv4 + IPv6:
        0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1

    The helper refuses to add bypass routes while it detects a WireGuard
    /0 route, so it will not silently claim success when Windows would block
    untunneled traffic.

.NOTES
    - Windows 10/11
    - Windows PowerShell 5.1 or PowerShell 7+
    - Administrator rights are required for route changes
    - Routes are created in ActiveStore and are not persistent across reboot
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("menu","add","add-chatgpt","remove","list","refresh","status","clear","reset")]
    [string]$Command = "menu",

    [Parameter(Position = 1)]
    [string]$Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateDir   = Join-Path $env:ProgramData "WG-VPN-Bypass"
$DomainsFile = Join-Path $StateDir "domains.txt"
$RoutesFile  = Join-Path $StateDir "routes.json"
$RouteMetric = 5

# Intentionally focused on core OpenAI/ChatGPT domains. Third-party shared
# services (for example generic Cloudflare/Stripe/Intercom endpoints) are not
# added automatically because IP-based bypass routes could also affect other
# sites sharing those addresses.
$ChatGPTPreset = @(
    "chatgpt.com",
    "*.chatgpt.com",
    "openai.com",
    "*.openai.com",
    "*.auth.openai.com",
    "*.oaistatic.com",
    "*.oaiusercontent.com",
    "*.oaistatsig.com",
    "cdn.openaimerge.com"
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Command", ('"{0}"' -f $Command)
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $args += @("-Value", ('"{0}"' -f $Value.Replace('"','\"')))
    }

    Start-Process "powershell.exe" -ArgumentList ($args -join " ") -Verb RunAs
    exit
}

function Ensure-Administrator {
    if (-not (Test-IsAdministrator)) {
        Write-Host "Administrator rights are required. Requesting elevation..."
        Start-Elevated
    }
}

function Ensure-State {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -Path $StateDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DomainsFile)) {
        New-Item -Path $DomainsFile -ItemType File -Force | Out-Null
    }
}

function Normalize-Domain([string]$Domain) {
    $d = $Domain.Trim().ToLowerInvariant()
    $d = $d -replace '^https?://',''
    $d = ($d -split '/')[0]
    $d = $d -replace ':\d+$',''
    $d = $d.TrimEnd('.')

    if ($d -notmatch '^(\*\.)?([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw "Invalid domain: $Domain"
    }
    return $d
}

function Get-Domains {
    Ensure-State
    return @(
        Get-Content -LiteralPath $DomainsFile -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Sort-Object -Unique
    )
}

function Save-Domains([AllowEmptyCollection()][string[]]$Domains) {
    Ensure-State
    @($Domains | Sort-Object -Unique) | Set-Content -LiteralPath $DomainsFile -Encoding ASCII
}

function Add-Domain([string]$Domain) {
    $d = Normalize-Domain $Domain
    $domains = @(Get-Domains)
    if ($domains -contains $d) {
        Write-Host "Already saved: $d"
        return
    }
    Save-Domains @($domains + $d)
    Write-Host "Added: $d"
}

function Remove-Domain([string]$Domain) {
    $d = Normalize-Domain $Domain
    $domains = @(Get-Domains)
    if ($domains -notcontains $d) {
        Write-Host "Not found: $d"
        return
    }
    Save-Domains @($domains | Where-Object { $_ -ne $d })
    Write-Host "Removed: $d"
}

function Get-SavedRoutes {
    if (-not (Test-Path -LiteralPath $RoutesFile)) { return @() }
    $raw = Get-Content -LiteralPath $RoutesFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try { return @($raw | ConvertFrom-Json) }
    catch {
        Write-Warning "Could not parse saved route state; treating it as empty."
        return @()
    }
}

function Save-Routes([AllowEmptyCollection()][object[]]$Routes) {
    Ensure-State
    if ($Routes.Count -eq 0) {
        Remove-Item -LiteralPath $RoutesFile -Force -ErrorAction SilentlyContinue
        return
    }
    $Routes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RoutesFile -Encoding UTF8
}

function Get-WireGuardInterfaceIndexes {
    return @(
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)wireguard' -or
            $_.InterfaceDescription -match '(?i)wireguard|wintun'
        } |
        Select-Object -ExpandProperty ifIndex -Unique
    )
}

function Test-WireGuardKillSwitchRoute {
    $indexes = @(Get-WireGuardInterfaceIndexes)
    foreach ($index in $indexes) {
        if (Get-NetRoute -InterfaceIndex $index -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue) {
            return $true
        }
        if (Get-NetRoute -InterfaceIndex $index -DestinationPrefix "::/0" -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Show-KillSwitchWarning {
    Write-Host ""
    Write-Host "WireGuard /0 full-tunnel route detected."
    Write-Host "A route-only bypass cannot reliably work while WireGuard for Windows"
    Write-Host "is using block-untunneled-traffic (kill-switch) semantics."
    Write-Host ""
    Write-Host "Change the client AllowedIPs before using this helper:"
    Write-Host ""
    Write-Host "IPv4 only:"
    Write-Host "  0.0.0.0/0"
    Write-Host "to:"
    Write-Host "  0.0.0.0/1, 128.0.0.0/1"
    Write-Host ""
    Write-Host "IPv4 + IPv6:"
    Write-Host "  0.0.0.0/0, ::/0"
    Write-Host "to:"
    Write-Host "  0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"
    Write-Host ""
    Write-Host "No WireGuard configuration was changed by this script."
}

function Get-NormalGateway([ValidateSet("IPv4","IPv6")][string]$Family) {
    $prefix = if ($Family -eq "IPv4") { "0.0.0.0/0" } else { "::/0" }
    $zeroHop = if ($Family -eq "IPv4") { "0.0.0.0" } else { "::" }

    $candidates = foreach ($route in @(Get-NetRoute -AddressFamily $Family -DestinationPrefix $prefix -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace([string]$route.NextHop) -or $route.NextHop -eq $zeroHop) { continue }

        $iface = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily $Family -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $iface -or $iface.ConnectionState -ne "Connected") { continue }

        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue
        $text = "$($iface.InterfaceAlias) $($adapter.Name) $($adapter.InterfaceDescription)"
        if ($text -match '(?i)wireguard|wintun') { continue }

        [PSCustomObject]@{
            AddressFamily = $Family
            InterfaceIndex = [uint32]$route.InterfaceIndex
            InterfaceAlias = [string]$iface.InterfaceAlias
            NextHop = [string]$route.NextHop
            Score = [int]$route.RouteMetric + [int]$iface.InterfaceMetric
        }
    }

    return @($candidates | Sort-Object Score | Select-Object -First 1)
}

function Get-NamesForPattern([string]$Pattern) {
    if (-not $Pattern.StartsWith("*.")) { return @($Pattern) }

    $apex = $Pattern.Substring(2)
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add($apex)

    try {
        foreach ($entry in @(Get-DnsClientCache -ErrorAction SilentlyContinue)) {
            $name = $null
            foreach ($prop in @("Entry","Name","RecordName")) {
                if ($entry.PSObject.Properties.Name -contains $prop) {
                    $name = [string]$entry.$prop
                    if ($name) { break }
                }
            }
            if (-not $name) { continue }

            $name = $name.TrimEnd('.').ToLowerInvariant()
            if ($name -eq $apex -or $name.EndsWith(".$apex")) {
                if (-not $names.Contains($name)) { $names.Add($name) }
            }
        }
    } catch {
        # DNS cache enumeration is optional.
    }

    return @($names | Sort-Object -Unique)
}

function Resolve-Pattern([string]$Pattern) {
    $results = @()

    foreach ($name in @(Get-NamesForPattern $Pattern)) {
        foreach ($type in @("A","AAAA")) {
            try {
                foreach ($record in @(Resolve-DnsName -Name $name -Type $type -DnsOnly -ErrorAction Stop)) {
                    if (-not ($record.PSObject.Properties.Name -contains "IPAddress")) { continue }
                    $ip = [string]$record.IPAddress
                    if (-not $ip) { continue }

                    $family = if ($ip -match ':') { "IPv6" } else { "IPv4" }
                    $results += [PSCustomObject]@{
                        Pattern = $Pattern
                        Name = $name
                        AddressFamily = $family
                        IPAddress = $ip
                    }
                }
            } catch {
                # A domain may legitimately have only one address family.
            }
        }
    }

    return @($results | Sort-Object Pattern,Name,AddressFamily,IPAddress -Unique)
}

function Remove-OwnedRoutes {
    foreach ($saved in @(Get-SavedRoutes)) {
        try {
            foreach ($route in @(
                Get-NetRoute -InterfaceIndex ([uint32]$saved.InterfaceIndex) `
                    -DestinationPrefix ([string]$saved.DestinationPrefix) `
                    -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -eq [string]$saved.NextHop }
            )) {
                Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
            }
        } catch {
            Write-Warning "Could not remove $($saved.DestinationPrefix): $($_.Exception.Message)"
        }
    }
    Save-Routes @()
}

function New-BypassRoute($Item, $Gateway) {
    $prefix = if ($Item.AddressFamily -eq "IPv4") { "$($Item.IPAddress)/32" } else { "$($Item.IPAddress)/128" }

    $existing = @(
        Get-NetRoute -InterfaceIndex ([uint32]$Gateway.InterfaceIndex) `
            -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq [string]$Gateway.NextHop }
    )
    if ($existing.Count -gt 0) { return $null }

    New-NetRoute -DestinationPrefix $prefix `
        -InterfaceIndex ([uint32]$Gateway.InterfaceIndex) `
        -NextHop ([string]$Gateway.NextHop) `
        -RouteMetric $RouteMetric `
        -PolicyStore ActiveStore `
        -ErrorAction Stop | Out-Null

    return [PSCustomObject]@{
        DomainPattern = $Item.Pattern
        ResolvedName = $Item.Name
        AddressFamily = $Item.AddressFamily
        IPAddress = $Item.IPAddress
        DestinationPrefix = $prefix
        InterfaceIndex = [uint32]$Gateway.InterfaceIndex
        InterfaceAlias = [string]$Gateway.InterfaceAlias
        NextHop = [string]$Gateway.NextHop
        Created = (Get-Date).ToString("o")
    }
}

function Refresh-Routes {
    $domains = @(Get-Domains)
    if ($domains.Count -eq 0) {
        Write-Host "No domains configured."
        return
    }

    if (Test-WireGuardKillSwitchRoute) {
        Show-KillSwitchWarning
        return
    }

    $gateway4 = Get-NormalGateway IPv4
    $gateway6 = Get-NormalGateway IPv6

    if ($null -eq $gateway4 -and $null -eq $gateway6) {
        throw "No normal non-WireGuard default gateway was found."
    }

    Remove-OwnedRoutes

    $created = @()
    foreach ($domain in $domains) {
        Write-Host "Resolving: $domain"
        foreach ($item in @(Resolve-Pattern $domain)) {
            $gateway = if ($item.AddressFamily -eq "IPv4") { $gateway4 } else { $gateway6 }
            if ($null -eq $gateway) { continue }

            try {
                $route = New-BypassRoute $item $gateway
                if ($null -ne $route) { $created += $route }
            } catch {
                Write-Warning "Route failed for $($item.Name) ($($item.IPAddress)): $($_.Exception.Message)"
            }
        }
    }

    Save-Routes $created
    Write-Host ""
    Write-Host "Created bypass routes: $($created.Count)"
    Write-Host "Run 'refresh' again if DNS addresses change."
}

function Show-List {
    $domains = @(Get-Domains)
    if ($domains.Count -eq 0) {
        Write-Host "No domains configured."
        return
    }
    $domains | ForEach-Object { Write-Host "  $_" }
}

function Show-Status {
    $domains = @(Get-Domains)
    $routes = @(Get-SavedRoutes)
    Write-Host "Saved domains:  $($domains.Count)"
    Write-Host "Tracked routes: $($routes.Count)"
    Write-Host "WG /0 route:    $(if (Test-WireGuardKillSwitchRoute) { 'Detected' } else { 'Not detected' })"

    $g4 = Get-NormalGateway IPv4
    $g6 = Get-NormalGateway IPv6

    if ($null -ne $g4) { Write-Host "IPv4 gateway:   $($g4.NextHop) via $($g4.InterfaceAlias)" }
    if ($null -ne $g6) { Write-Host "IPv6 gateway:   $($g6.NextHop) via $($g6.InterfaceAlias)" }
}

function Add-ChatGPTPreset {
    foreach ($domain in $ChatGPTPreset) { Add-Domain $domain }
    Write-Host ""
    Write-Host "ChatGPT/OpenAI preset added."
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "WG VPN Domain Bypass"
        Write-Host "===================="
        Write-Host ""
        Write-Host "1. Add excluded domain"
        Write-Host "2. Add ChatGPT/OpenAI preset"
        Write-Host "3. Remove excluded domain"
        Write-Host "4. List excluded domains"
        Write-Host "5. Refresh bypass routes"
        Write-Host "6. Show status"
        Write-Host "7. Clear active bypass routes"
        Write-Host "8. Reset all"
        Write-Host "9. Exit"
        Write-Host ""

        try {
            switch (Read-Host "Select") {
                "1" {
                    Add-Domain (Read-Host "Domain")
                    if ((Read-Host "Refresh routes now? [Y/n]") -notmatch '^(?i)n$') { Refresh-Routes }
                }
                "2" {
                    Add-ChatGPTPreset
                    if ((Read-Host "Refresh routes now? [Y/n]") -notmatch '^(?i)n$') { Refresh-Routes }
                }
                "3" {
                    Remove-Domain (Read-Host "Domain")
                    Refresh-Routes
                }
                "4" { Show-List }
                "5" { Refresh-Routes }
                "6" { Show-Status }
                "7" { Remove-OwnedRoutes; Write-Host "Active bypass routes removed. Saved domains kept." }
                "8" {
                    if ((Read-Host "Remove all saved domains and tracked routes? [y/N]") -match '^(?i)y$') {
                        Remove-OwnedRoutes
                        Save-Domains @()
                        Write-Host "Reset complete."
                    }
                }
                "9" { return }
                default { Write-Host "Invalid selection." }
            }
        } catch {
            Write-Host "Error: $($_.Exception.Message)"
        }

        Write-Host ""
        Read-Host "Press Enter to continue" | Out-Null
    }
}

Ensure-Administrator
Ensure-State

switch ($Command) {
    "menu" { Show-Menu }
    "add" {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "Usage: .\wg-vpn-bypass.ps1 add <domain>" }
        Add-Domain $Value
        Refresh-Routes
    }
    "add-chatgpt" {
        Add-ChatGPTPreset
        Refresh-Routes
    }
    "remove" {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "Usage: .\wg-vpn-bypass.ps1 remove <domain>" }
        Remove-Domain $Value
        Refresh-Routes
    }
    "list" { Show-List }
    "refresh" { Refresh-Routes }
    "status" { Show-Status }
    "clear" {
        Remove-OwnedRoutes
        Write-Host "Active bypass routes removed. Saved domains kept."
    }
    "reset" {
        Remove-OwnedRoutes
        Save-Domains @()
        Write-Host "All saved domains and tracked routes removed."
    }
}
