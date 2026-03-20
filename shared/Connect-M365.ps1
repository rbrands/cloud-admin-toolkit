<#
.SYNOPSIS
    Opens connections to Microsoft 365 services used by the Cloud Admin Toolkit.

.DESCRIPTION
    Connects interactively to one or more Microsoft 365 services:

      - Microsoft Graph          (Connect-MgGraph)
      - Microsoft Teams          (Connect-MicrosoftTeams)
      - SharePoint Online / PnP  (Connect-PnPOnline  →  tenant admin center)
      - Exchange Online          (Connect-ExchangeOnline)

    By default ALL four services are connected. Use -Graph, -Teams,
    -SharePoint, -Exchange to connect only the selected services.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Connect-M365.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    # Connect to all services using a named config
    .\Connect-M365.ps1 -ConfigName prod

.EXAMPLE
    # Connect only Graph and Exchange
    .\Connect-M365.ps1 -ConfigName prod -Graph -Exchange

.EXAMPLE
    # Fully explicit, no config file
    .\Connect-M365.ps1 -TenantId '<guid>' -TenantAdminUrl 'https://contoso-admin.sharepoint.com'

.EXAMPLE
    # Device code flow (e.g. from a headless terminal)
    .\Connect-M365.ps1 -ConfigName prod -UseDeviceAuthentication

.NOTES
    Prerequisites:
      Microsoft.Graph             module
      MicrosoftTeams              module
      PnP.PowerShell              module
      ExchangeOnlineManagement    module
      Run .\Install-Prerequisites.ps1 to install all modules.

    Default Graph scopes (override via config graphScopes or -GraphScopes):
      User.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All,
      Sites.ReadWrite.All, Mail.ReadWrite
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    # Directory to search for the config file. Defaults to the script directory.
    [Parameter(Mandatory = $false)]
    [string]$ConfigDir,

    # Entra ID tenant ID (GUID).
    # Overrides tenantId in the config file.
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    # SharePoint Online tenant admin URL, e.g. https://contoso-admin.sharepoint.com
    # Required for SharePoint / PnP connection.
    # Overrides tenantAdminUrl in the config file.
    [Parameter(Mandatory = $false)]
    [string]$TenantAdminUrl,

    # Entra ID App Registration Client ID for PnP.PowerShell (required by PnP v2+).
    # Overrides pnpClientId in the config file.
    [Parameter(Mandatory = $false)]
    [string]$PnpClientId,

    # Microsoft Graph delegated permission scopes to request.
    # Overrides graphScopes in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$GraphScopes,

    # Use device-code authentication flow (suitable for headless / SSH sessions).
    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication,

    # Use device-code authentication specifically for Exchange Online.
    # If omitted, -UseDeviceAuthentication is used as a fallback.
    [Parameter(Mandatory = $false)]
    [switch]$ExchangeUseDeviceAuthentication,

    # Disable Web Account Manager (WAM) for Exchange Online auth.
    # Useful when interactive broker login fails in some host environments.
    [Parameter(Mandatory = $false)]
    [switch]$ExchangeDisableWAM,

    # ── Service selection ──────────────────────────────────────────────────────
    # When none of these switches is specified, ALL services are connected.

    [Parameter(Mandatory = $false)]
    [switch]$Graph,

    [Parameter(Mandatory = $false)]
    [switch]$Teams,

    [Parameter(Mandatory = $false)]
    [switch]$SharePoint,

    [Parameter(Mandatory = $false)]
    [switch]$Exchange
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Connect-M365'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $TenantId -and $null -ne $config -and $config.tenantId) {
    $TenantId = $config.tenantId
}

if (-not $TenantAdminUrl -and $null -ne $config -and $config.tenantAdminUrl) {
    $TenantAdminUrl = $config.tenantAdminUrl
}

if (-not $PnpClientId -and $null -ne $config -and $config.PSObject.Properties['pnpClientId']) {
    $PnpClientId = $config.pnpClientId
}

if (-not $GraphScopes -and $null -ne $config -and $config.graphScopes) {
    $GraphScopes = [string[]]$config.graphScopes
}

if (-not $UseDeviceAuthentication -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and $config.auth.useDeviceAuthentication -eq $true) {
    $UseDeviceAuthentication = $true
}

if (-not $ExchangeUseDeviceAuthentication -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['exchangeUseDeviceAuthentication'] -and
    $config.auth.exchangeUseDeviceAuthentication -eq $true) {
    $ExchangeUseDeviceAuthentication = $true
}

if (-not $ExchangeDisableWAM -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['exchangeDisableWAM'] -and
    $config.auth.exchangeDisableWAM -eq $true) {
    $ExchangeDisableWAM = $true
}

# ── Service selection: if none specified, connect to all ──────────────────────

$connectAll = -not ($Graph -or $Teams -or $SharePoint -or $Exchange)
if ($connectAll) {
    $Graph      = $true
    $Teams      = $true
    $SharePoint = $true
    $Exchange   = $true
}

# ── Default Graph scopes ──────────────────────────────────────────────────────

if (-not $GraphScopes) {
    $GraphScopes = @(
        'User.ReadWrite.All'
        'Group.ReadWrite.All'
        'Directory.ReadWrite.All'
        'Sites.ReadWrite.All'
        'Mail.ReadWrite'
    )
}

# ── Validation ────────────────────────────────────────────────────────────────

if ($SharePoint -and -not $TenantAdminUrl) {
    Write-Host "No TenantAdminUrl provided. SharePoint connection requires -TenantAdminUrl or tenantAdminUrl in the config file." -ForegroundColor Red
    exit 1
}

# ── Header ────────────────────────────────────────────────────────────────────

Write-Host "=== Connect-M365 ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config     : $resolvedConfigPath" -ForegroundColor Gray
}
if ($TenantId) {
    Write-Host "Tenant     : $TenantId" -ForegroundColor Gray
}
Write-Host "Services   : $((@(
    if ($Graph)      { 'Graph' }
    if ($Teams)      { 'Teams' }
    if ($SharePoint) { 'SharePoint' }
    if ($Exchange)   { 'Exchange' }
) -join ', '))" -ForegroundColor Gray
Write-Host "Auth       : $(if ($UseDeviceAuthentication) { 'Device code' } else { 'Interactive browser' })" -ForegroundColor Gray
Write-Host ""

$results = [ordered]@{}

# ── Microsoft Graph ───────────────────────────────────────────────────────────

if ($Graph) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    try {
        $graphParams = @{
            Scopes      = $GraphScopes
            ErrorAction = 'Stop'
            NoWelcome   = $true
        }
        if ($TenantId)                { $graphParams.TenantId  = $TenantId }
        if ($UseDeviceAuthentication) { $graphParams.UseDeviceAuthentication = $true }

        Connect-MgGraph @graphParams

        $mgCtx = Get-MgContext
        Write-Host "  Connected: $($mgCtx.Account)  |  Tenant: $($mgCtx.TenantId)" -ForegroundColor Green
        $results['Graph'] = 'OK'
    }
    catch {
        Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
        $results['Graph'] = 'FAILED'
    }
    Write-Host ""
}

# ── Microsoft Teams ───────────────────────────────────────────────────────────

if ($Teams) {
    Write-Host "Connecting to Microsoft Teams..." -ForegroundColor Cyan
    try {
        Import-Module MicrosoftTeams -ErrorAction Stop
        if (-not (Get-Command Connect-MicrosoftTeams -ErrorAction SilentlyContinue)) {
            throw "MicrosoftTeams module is installed, but Connect-MicrosoftTeams is not available in the current session."
        }

        $teamsParams = @{ ErrorAction = 'Stop' }
        if ($TenantId)                { $teamsParams.TenantId = $TenantId }
        if ($UseDeviceAuthentication) { $teamsParams.UseDeviceAuthentication = $true }

        Connect-MicrosoftTeams @teamsParams | Out-Null

        $tenant = Get-CsTenant -ErrorAction Stop
        Write-Host "  Connected: $($tenant.DisplayName)  ($($tenant.TenantId))" -ForegroundColor Green
        $results['Teams'] = 'OK'
    }
    catch {
        Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
        $results['Teams'] = 'FAILED'
    }
    Write-Host ""
}

# ── SharePoint Online (PnP) ───────────────────────────────────────────────────

if ($SharePoint) {
    Write-Host "Connecting to SharePoint Online (tenant admin)..." -ForegroundColor Cyan
    Write-Host "  URL: $TenantAdminUrl" -ForegroundColor Gray
    try {
        $pnpParams = @{
            Url         = $TenantAdminUrl
            Interactive = $true
            ErrorAction = 'Stop'
        }
        if ($PnpClientId) { $pnpParams.ClientId = $PnpClientId }

        Connect-PnPOnline @pnpParams

        $pnpConn = Get-PnPConnection -ErrorAction Stop
        Write-Host "  Connected: $($pnpConn.Url)" -ForegroundColor Green
        $results['SharePoint'] = 'OK'
    }
    catch {
        Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
        $results['SharePoint'] = 'FAILED'
    }
    Write-Host ""
}

# ── Exchange Online ───────────────────────────────────────────────────────────

if ($Exchange) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    try {
        $exoCommand = Get-Command Connect-ExchangeOnline -ErrorAction Stop
        $exoSupportsDevice     = $exoCommand.Parameters.ContainsKey('Device')
        $exoSupportsDisableWAM = $exoCommand.Parameters.ContainsKey('DisableWAM')

        $exchangeParams = @{
            ShowBanner  = $false
            ErrorAction = 'Stop'
        }

        $useExchangeDeviceAuth = $ExchangeUseDeviceAuthentication -or $UseDeviceAuthentication
        if ($useExchangeDeviceAuth) {
            if ($exoSupportsDevice) {
                $exchangeParams.Device = $true
            }
            else {
                Write-Host "  Warning: Installed ExchangeOnlineManagement module does not support -Device. Continuing with interactive auth." -ForegroundColor Yellow
            }
        }

        if ($ExchangeDisableWAM) {
            if ($exoSupportsDisableWAM) {
                $exchangeParams.DisableWAM = $true
            }
            else {
                Write-Host "  Warning: Installed ExchangeOnlineManagement module does not support -DisableWAM." -ForegroundColor Yellow
            }
        }

        try {
            Connect-ExchangeOnline @exchangeParams
        }
        catch {
            $firstExchangeError = $_
            $errorText = $firstExchangeError.Exception.Message
            $looksLikeBrokerIssue =
                $errorText -match 'CreateBroker' -or
                $errorText -match 'MSAL' -or
                $errorText -match 'Object reference not set to an instance of an object'

            $canRetryWithDisableWAM = -not $ExchangeDisableWAM -and $exoSupportsDisableWAM
            if (-not $canRetryWithDisableWAM -or -not $looksLikeBrokerIssue) {
                throw
            }

            Write-Host "  Warning: Exchange interactive broker auth failed. Retrying with -DisableWAM..." -ForegroundColor Yellow
            $retryExchangeParams = @{} + $exchangeParams
            $retryExchangeParams.DisableWAM = $true
            Connect-ExchangeOnline @retryExchangeParams
        }

        Write-Host "  Connected" -ForegroundColor Green
        $results['Exchange'] = 'OK'
    }
    catch {
        Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
        $results['Exchange'] = 'FAILED'
    }
    Write-Host ""
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "=== Summary ===" -ForegroundColor Cyan
foreach ($svc in $results.Keys) {
    $status = $results[$svc]
    $color  = if ($status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12}: {1}" -f $svc, $status) -ForegroundColor $color
}

$failedCount = @($results.Values | Where-Object { $_ -eq 'FAILED' }).Count
if ($failedCount -gt 0) {
    Write-Host ""
    Write-Host "$failedCount service(s) failed to connect." -ForegroundColor Red
    exit 1
}
