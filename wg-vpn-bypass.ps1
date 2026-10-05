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
$VerbosePreference = "Continue"

$StateDir   = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "WG-VPN-Bypass"
$DomainsFile = Join-Path $StateDir "domains.txt"
$RoutesFile  = Join-Path $StateDir "routes.json"
$RouteMetric = Get-Random -Minimum 20000 -Maximum 60000
$BootId = $null

# Intentionally focused on core OpenAI/ChatGPT domains. Third-party shared
# services (for example generic Cloudflare/Stripe/Intercom endpoints) are not
# added automatically because IP-based bypass routes could also affect other
# sites sharing those addresses.
$ChatGPTPreset = @(
    "chatgpt.com",
    "openai.com",
    "auth.openai.com",
    "auth0.openai.com",
    "chat.openai.com",
    "desktop.chat.openai.com",
    "setup.auth.openai.com",
    "cdn.openaimerge.com"
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ElevationCode([string]$ScriptPath, [string]$RequestedCommand, [string]$RequestedValue) {
    # Encode data, never interpolate caller input as PowerShell source.
    $payload = @{ Path = $ScriptPath; Command = $RequestedCommand; Value = $RequestedValue } | ConvertTo-Json -Compress
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $code = '$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $data + ''')) | ConvertFrom-Json; & $p.Path -Command $p.Command -Value $p.Value'
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
}

function Start-Elevated {
    $encoded = Get-ElevationCode $PSCommandPath $Command $Value
    $hostExe = Join-Path $PSHOME 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
    $process = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
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
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
        Set-Acl -LiteralPath $StateDir -AclObject $acl
    }
    Assert-SafeStatePath $StateDir
    foreach ($path in @($DomainsFile, $RoutesFile, (Join-Path $StateDir 'state.lock'))) {
        if (Test-Path -LiteralPath $path) { Assert-SafeStatePath $path }
    }
    if (-not (Test-Path -LiteralPath $DomainsFile)) {
        New-Item -Path $DomainsFile -ItemType File -Force | Out-Null
    }
}

function Assert-SafeStatePath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "State path is a link: $Path" }
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw "Unsafe state owner: $Path. Archive the old state as Administrator and start with a fresh directory; do not import old route metadata."
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted) {
            throw "Untrusted state permissions: $Path. Archive the old state as Administrator and start with a fresh directory."
        }
    }
}

function Write-StateFile([string]$Path, [string]$Text) {
    $temp = Join-Path $StateDir ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Normalize-Domain([string]$Domain) {
    $d = $Domain.Trim().ToLowerInvariant()
    $d = $d -replace '^https?://',''
    $d = ($d -split '/')[0]
    $d = $d -replace ':\d+$',''
    $d = $d.TrimEnd('.')

    if ($d.StartsWith('*.')) { throw 'Use an exact hostname; wildcard bypass cannot cover all subdomains.' }
    if ($d.Length -gt 253 -or $d -notmatch '^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw "Invalid domain: $Domain"
    }
    return $d
}

function Get-Domains {
    Ensure-State
    return @(
        Get-Content -LiteralPath $DomainsFile -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() } |
        ForEach-Object { Normalize-Domain $_ } |
        Sort-Object -Unique
    )
}

function Save-Domains([AllowEmptyCollection()][string[]]$Domains) {
    Ensure-State
    Write-StateFile $DomainsFile ((@($Domains | Sort-Object -Unique) -join "`n") + "`n")
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
    try {
        $parsed = $raw | ConvertFrom-Json
        foreach ($row in $parsed) { $row }
    }
    catch {
        throw 'Route state is corrupt. Preserve it for inspection; no routes were changed.'
    }
}

function Save-Routes([AllowEmptyCollection()][object[]]$Routes) {
    Ensure-State
    Write-StateFile $RoutesFile (ConvertTo-Json -InputObject @($Routes) -Depth 5)
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
    Write-Warning 'The /1 change removes the WireGuard-specific kill switch, including its DNS restrictions. Reconnect the tunnel after editing it manually.'
}

function Get-NormalGateway([ValidateSet("IPv4","IPv6")][string]$Family) {
    $prefix = if ($Family -eq "IPv4") { "0.0.0.0/0" } else { "::/0" }
    $zeroHop = if ($Family -eq "IPv4") { "0.0.0.0" } else { "::" }

    $candidates = foreach ($route in @(Get-NetRoute -AddressFamily $Family -PolicyStore ActiveStore -ErrorAction Stop | Where-Object DestinationPrefix -eq $prefix)) {
        if ([string]::IsNullOrWhiteSpace([string]$route.NextHop) -or $route.NextHop -eq $zeroHop) { continue }

        $iface = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily $Family -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $iface -or $iface.ConnectionState -ne "Connected") { continue }

        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue
        if ($null -eq $adapter -or -not $adapter.HardwareInterface -or $adapter.Status -ne 'Up') { continue }
        $text = "$($iface.InterfaceAlias) $($adapter.Name) $($adapter.InterfaceDescription)"
        if ($text -match '(?i)wireguard|wintun') { continue }

        [PSCustomObject]@{
            AddressFamily = $Family
            InterfaceIndex = [uint32]$route.InterfaceIndex
            InterfaceAlias = [string]$iface.InterfaceAlias
            InterfaceGuid = [string]$adapter.InterfaceGuid
            NextHop = [string]$route.NextHop
            Score = [int]$route.RouteMetric + [int]$iface.InterfaceMetric
        }
    }

    return @($candidates | Sort-Object Score | Select-Object -First 1)
}

function Get-NamesForPattern([string]$Pattern) {
    return @(Normalize-Domain $Pattern)
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
                    $parsed = $null
                    if (-not [Net.IPAddress]::TryParse($ip, [ref]$parsed)) { continue }
                    if ([Net.IPAddress]::IsLoopback($parsed) -or $parsed.IsIPv4MappedToIPv6 -or
                        $parsed.IsIPv6LinkLocal -or $parsed.IsIPv6Multicast -or $ip -in @('0.0.0.0','::')) { continue }
                    if ($parsed.AddressFamily -eq 'InterNetwork' -and
                        ($parsed.GetAddressBytes()[0] -ge 224 -or $ip -like '169.254.*')) { continue }
                    $ip = $parsed.ToString()

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
    $remaining = @()
    foreach ($saved in @(Get-SavedRoutes)) {
        try {
            foreach ($field in @('BootId','RouteMetric','InterfaceGuid','DestinationPrefix','InterfaceIndex','NextHop')) {
                if ($saved.PSObject.Properties.Name -notcontains $field) {
                    throw 'Legacy or incomplete ownership metadata; inspect manually or reboot to expire temporary routes.'
                }
            }
            if ($saved.BootId -ne $BootId) { continue }
            $parts = ([string]$saved.DestinationPrefix).Split('/')
            $address = $null
            if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
                $parts[1] -ne $(if ($address.AddressFamily -eq 'InterNetwork') { '32' } else { '128' }) -or
                [int]$saved.RouteMetric -lt 20000 -or [int]$saved.RouteMetric -ge 60000) {
                throw 'Invalid ownership metadata; refusing route deletion.'
            }
            $adapter = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object ifIndex -eq ([uint32]$saved.InterfaceIndex)
            if ($null -eq $adapter -or [string]$adapter.InterfaceGuid -ne [string]$saved.InterfaceGuid) {
                Write-Warning "Interface changed; leaving $($saved.DestinationPrefix) untouched."
                continue
            }
            foreach ($route in @(
                Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop |
                Where-Object { $_.InterfaceIndex -eq [uint32]$saved.InterfaceIndex -and
                    $_.DestinationPrefix -eq [string]$saved.DestinationPrefix -and
                    $_.NextHop -eq [string]$saved.NextHop -and
                    $_.RouteMetric -eq [int]$saved.RouteMetric -and $_.Protocol -eq 'NetMgmt' }
            )) {
                Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
            }
        } catch {
            $remaining += $saved
            Write-Warning "Could not remove $($saved.DestinationPrefix): $($_.Exception.Message)"
        }
    }
    Save-Routes $remaining
    if ($remaining.Count -gt 0) { throw 'Some routes could not be cleaned up. State was retained; retry clear before refresh/reset.' }
}

function New-BypassRoute($Item, $Gateway) {
    $prefix = if ($Item.AddressFamily -eq "IPv4") { "$($Item.IPAddress)/32" } else { "$($Item.IPAddress)/128" }

    $existing = @(
        Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object DestinationPrefix -eq $prefix
    )
    if ($existing.Count -gt 0) { Write-Warning "Existing host route left untouched: $prefix"; return $null }

    New-NetRoute -DestinationPrefix $prefix `
        -InterfaceIndex ([uint32]$Gateway.InterfaceIndex) `
        -NextHop ([string]$Gateway.NextHop) `
        -RouteMetric $RouteMetric `
        -Protocol NetMgmt `
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
        InterfaceGuid = [string]$Gateway.InterfaceGuid
        NextHop = [string]$Gateway.NextHop
        RouteMetric = $RouteMetric
        BootId = $BootId
        Created = (Get-Date).ToString("o")
    }
}

function Refresh-Routes {
    $domains = @(Get-Domains)
    if ($domains.Count -eq 0) {
        Remove-OwnedRoutes
        Write-Host "No domains configured."
        return
    }

    if (Test-WireGuardKillSwitchRoute) {
        Show-KillSwitchWarning
        throw 'Bypass blocked by a detected WireGuard /0 route. Make the manual client change shown above.'
    }

    $gateway4 = Get-NormalGateway IPv4
    $gateway6 = Get-NormalGateway IPv6

    if ($null -eq $gateway4 -and $null -eq $gateway6) {
        throw "No normal non-WireGuard default gateway was found."
    }

    # Resolve before removing working routes; a failed hostname must not silently
    # replace the whole bypass set with an empty or partial result.
    $resolved = @()
    foreach ($domain in $domains) {
        Write-Host "Resolving: $domain"
        $items = @(Resolve-Pattern $domain)
        if ($items.Count -eq 0) { throw "No usable DNS addresses for $domain. Existing routes kept; check DNS or remove this hostname and retry." }
        $usable = @($items | Where-Object { ($_.AddressFamily -eq 'IPv4' -and $null -ne $gateway4) -or ($_.AddressFamily -eq 'IPv6' -and $null -ne $gateway6) })
        if ($usable.Count -eq 0) { throw "No physical gateway for the addresses of $domain. Existing routes kept; check your network connection." }
        $resolved += $items
    }
    Remove-OwnedRoutes

    $created = @()
    $failed = $false
    foreach ($item in @($resolved | Sort-Object AddressFamily,IPAddress -Unique)) {
            $gateway = if ($item.AddressFamily -eq "IPv4") { $gateway4 } else { $gateway6 }
            if ($null -eq $gateway) { Write-Warning "No physical gateway for $($item.AddressFamily); skipped $($item.IPAddress)."; continue }

            try {
                $route = New-BypassRoute $item $gateway
            } catch {
                $failed = $true
                Write-Warning "Route failed for $($item.Name) ($($item.IPAddress)): $($_.Exception.Message)"
                continue
            }
            if ($null -ne $route) {
                $created += $route
                # Persist each success, not just the final batch. A forced process
                # termination in the add/save gap can still leave an orphan.
                Save-Routes $created
            }
        }

    Save-Routes $created
    Write-Host ""
    Write-Host "Created bypass routes: $($created.Count)"
    Write-Host "Run 'refresh' again if DNS addresses change."
    if ($failed) { throw 'Some bypass routes failed. Successful routes remain tracked; check the warnings and retry refresh.' }
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
$BootId = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$stateLock = $null
try {
    $stateLock = [IO.File]::Open((Join-Path $StateDir 'state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch { throw 'Another helper may be running, or the state lock is inaccessible. Close the other helper and retry.' }

try {
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
} finally { $stateLock.Dispose() }
