# Offline regression checks: load function ASTs only, never the elevated entry point.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'wg-vpn-bypass.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Ensure-State {}
$StateDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $StateDir | Out-Null
$DomainsFile = Join-Path $StateDir 'domains.txt'
$RoutesFile = Join-Path $StateDir 'routes.json'
$BootId = 'test-boot'
$RouteMetric = 23456
$script:deleted = @()
$script:live = @()
function Get-NetRoute { param($PolicyStore, $ErrorAction) $script:live }
function Get-NetAdapter { param($InterfaceIndex, [switch]$IncludeHidden, $ErrorAction)
    [pscustomobject]@{ifIndex=2; InterfaceGuid='test-guid'; HardwareInterface=$true; Status='Up'; Name='Ethernet'; InterfaceDescription='Ethernet'}
}
function Remove-NetRoute { param($InputObject, $Confirm, $ErrorAction)
    if ($script:failDelete) { throw 'simulated delete failure' }
    $script:deleted += $InputObject
}
$script:failDelete = $false
try {
    # Decode the elevation transport and invoke a harmless capture script. Quotes,
    # trailing backslashes and PowerShell metacharacters must remain data.
    $capture = Join-Path $StateDir "capture ' space.ps1"
    [IO.File]::WriteAllText($capture, 'param($Command,$Value) [pscustomobject]@{Command=$Command;Value=$Value}')
    foreach ($value in @('', 'x"; throw ''injected''; #', 'space and trailing\', '$(throw ''injected'')')) {
        $encoded = Get-ElevationCode $capture 'add' $value
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $result = & ([scriptblock]::Create($decoded))
        Assert ($result.Value -ceq $value -and $result.Command -eq 'add') 'elevation argument changed'
    }
    Remove-Item -LiteralPath $capture
    Assert ((Normalize-Domain 'https://Example.com/path') -eq 'example.com') 'domain normalization'
    foreach ($bad in @('*.example.com', 'x;whoami.com', 'x".com', ('a' * 254))) {
        $rejected = $false
        try { Normalize-Domain $bad | Out-Null } catch { $rejected = $true }
        Assert $rejected "unsafe/wildcard accepted: $bad"
    }
    Save-Domains @('example.com')
    Save-Domains @()
    Assert (@(Get-Domains).Count -eq 0) 'last domain was not cleared'
    $saved = [pscustomobject]@{BootId=$BootId; RouteMetric=23456; InterfaceGuid='test-guid'; DestinationPrefix='203.0.113.1/32'; InterfaceIndex=2; NextHop='192.0.2.1'}
    $script:live = @([pscustomobject]@{DestinationPrefix='203.0.113.1/32'; InterfaceIndex=2; NextHop='192.0.2.1'; RouteMetric=5; Protocol='NetMgmt'})
    Save-Routes @($saved)
    Remove-OwnedRoutes
    Assert ($script:deleted.Count -eq 0) 'removed a different-metric route'
    $script:live[0].RouteMetric = 23456
    Save-Routes @($saved)
    $script:failDelete = $true
    try { Remove-OwnedRoutes; throw 'expected failure' } catch { Assert (@(Get-SavedRoutes).Count -eq 1) 'lost failed deletion state' }
    $script:failDelete = $false
    # Empty domain refresh must clean up, without gateway or DNS discovery.
    Refresh-Routes
    Assert ($script:deleted.Count -eq 1) 'last-domain refresh did not delete owned route'
    Assert (@(Get-SavedRoutes).Count -eq 0) 'cleanup state not empty'
    $saved.BootId = 'previous-boot'
    Save-Routes @($saved)
    Remove-OwnedRoutes
    Assert ($script:deleted.Count -eq 1) 'removed route using stale reboot metadata'
    $saved.BootId = $BootId
    $saved.DestinationPrefix = '0.0.0.0/0'
    Save-Routes @($saved)
    try { Remove-OwnedRoutes } catch {}
    Assert ($script:deleted.Count -eq 1) 'removed a non-host route'
    Save-Routes @()
    Save-Domains @('example.com')
    function Test-WireGuardKillSwitchRoute { $false }
    function Get-NormalGateway { param($Family) [pscustomobject]@{NextHop='192.0.2.1'} }
    function Resolve-Pattern { param($Pattern) @() }
    Save-Routes @([pscustomobject]@{Sentinel='preserved'})
    $rejected = $false
    try { Refresh-Routes } catch { $rejected = $true }
    Assert $rejected 'DNS failure not reported'
    Assert ((Get-SavedRoutes).Sentinel -eq 'preserved') 'DNS failure discarded existing state'
    Write-Host "PASS: offline Windows bypass checks ($($PSVersionTable.PSVersion))"
} finally {
    Remove-Item -LiteralPath $DomainsFile, $RoutesFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateDir -Force
}
