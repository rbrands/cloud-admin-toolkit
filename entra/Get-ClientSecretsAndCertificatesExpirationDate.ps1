<#
.SYNOPSIS
    Lists expiration dates of client secrets and certificates for all Entra ID App Registrations.

.DESCRIPTION
    Queries all App Registrations in the connected Entra ID tenant and reports
    the expiration dates of their client secrets (PasswordCredentials) and
    client certificates (KeyCredentials).

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Get-ClientSecretsAndCertificatesExpirationDate.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Get-ClientSecretsAndCertificatesExpirationDate.ps1

.EXAMPLE
    .\Get-ClientSecretsAndCertificatesExpirationDate.ps1 -ExpiringWithinDays 30

.EXAMPLE
    .\Get-ClientSecretsAndCertificatesExpirationDate.ps1 -IncludeExpired -ExportCsv

.EXAMPLE
    .\Get-ClientSecretsAndCertificatesExpirationDate.ps1 -AppDisplayNameFilter 'MyApp' -ExpiringWithinDays 90

.EXAMPLE
    .\Get-ClientSecretsAndCertificatesExpirationDate.ps1 -ConfigName contoso

.NOTES
    Required Microsoft Entra permission:
      Application.Read.All
    Prerequisites:
      Az.Resources module (run .\shared\Install-Prerequisites.ps1)

    Status thresholds:
      Expired  : credential end date is in the past
      Critical : expires within 30 days
      Warning  : expires within 31–90 days
      OK       : expires in more than 90 days
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

    # Only include credentials expiring within this number of days.
    # 0 means no upper limit – all non-expired credentials are shown.
    [Parameter(Mandatory = $false)]
    [int]$ExpiringWithinDays = 0,

    # Include credentials that have already expired.
    [Parameter(Mandatory = $false)]
    [switch]$IncludeExpired = $true,

    # Optional substring filter on the App Registration display name (case-insensitive).
    [Parameter(Mandatory = $false)]
    [string]$AppDisplayNameFilter,

    # Export results to a CSV file in the script directory (or export.outputDir from config).
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ============================================================================
# Load config file and merge parameters
# ============================================================================

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Get-ClientSecretsAndCertificatesExpirationDate'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath
$exportOutputDir = $PSScriptRoot

if ($null -ne $config) {
    $searchCfg = $config.PSObject.Properties['search']?.Value
    $exportCfg = $config.PSObject.Properties['export']?.Value

    if ($null -ne $searchCfg) {
        if ($ExpiringWithinDays -eq 0) {
            $cfgDays = $searchCfg.PSObject.Properties['expiringWithinDays']?.Value
            if ($cfgDays) { $ExpiringWithinDays = [int]$cfgDays }
        }
        if (-not $IncludeExpired.IsPresent) {
            $cfgIncludeExpired = $searchCfg.PSObject.Properties['includeExpired']?.Value
            if ($cfgIncludeExpired -eq $true) { $IncludeExpired = $true }
        }
        if (-not $AppDisplayNameFilter) {
            $cfgFilter = $searchCfg.PSObject.Properties['appDisplayNameFilter']?.Value
            if ($cfgFilter) { $AppDisplayNameFilter = $cfgFilter }
        }
    }

    if ($null -ne $exportCfg) {
        if (-not $ExportCsv.IsPresent) {
            $csvFlag = $exportCfg.PSObject.Properties['csv']?.Value
            if ($csvFlag -eq $true) { $ExportCsv = $true }
        }
        $cfgOutputDir = $exportCfg.PSObject.Properties['outputDir']?.Value
        if ($cfgOutputDir) { $exportOutputDir = $cfgOutputDir }
    }
}

# ============================================================================
# Verify Azure / Entra context
# ============================================================================

try {
    $azContext = Get-AzContext -ErrorAction Stop
    if (-not $azContext) { throw 'No context' }
    Write-Host "Azure connection active: $($azContext.Account.Id) | Tenant: $($azContext.Tenant.Id)" -ForegroundColor DarkGray
}
catch {
    Write-Host 'Connecting to Azure / Entra ID...' -ForegroundColor Yellow
    $null = Connect-AzAccount
}

# ============================================================================
# Load App Registrations
# ============================================================================

Write-Host ''
Write-Host '=== Get-ClientSecretsAndCertificatesExpirationDate ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Loading App Registrations from Entra ID...' -ForegroundColor Cyan

$apps = Get-AzADApplication -ErrorAction Stop

if ($AppDisplayNameFilter) {
    $apps = $apps | Where-Object { $_.DisplayName -ilike "*$AppDisplayNameFilter*" }
    Write-Host "  Filtered by display name '*$AppDisplayNameFilter*': $($apps.Count) app(s)." -ForegroundColor DarkGray
}
else {
    Write-Host "  $($apps.Count) app(s) found." -ForegroundColor DarkGray
}

Write-Host ''

# ============================================================================
# Collect credential information
# ============================================================================

$now        = Get-Date
$cutoffDate = if ($ExpiringWithinDays -gt 0) { $now.AddDays($ExpiringWithinDays) } else { $null }
$results    = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($app in $apps) {

    # --- Client secrets (PasswordCredentials) ---
    foreach ($secret in $app.PasswordCredentials) {
        $endDate = $secret.EndDateTime
        if (-not $endDate) { continue }

        $isExpired = $endDate -lt $now
        $daysLeft  = [math]::Ceiling(($endDate - $now).TotalDays)

        if ($isExpired -and -not $IncludeExpired) { continue }
        if ($cutoffDate -and (-not $isExpired) -and $endDate -gt $cutoffDate) { continue }

        $results.Add([PSCustomObject]@{
            AppDisplayName = $app.DisplayName
            AppId          = $app.AppId
            Type           = 'Secret'
            CredentialName = if ($secret.DisplayName) { $secret.DisplayName } else { '(unnamed)' }
            KeyId          = $secret.KeyId
            ExpirationDate = $endDate.ToString('yyyy-MM-dd')
            DaysLeft       = $daysLeft
            Status         = if ($isExpired) { 'Expired' }
                             elseif ($daysLeft -le 30) { 'Critical' }
                             elseif ($daysLeft -le 90) { 'Warning' }
                             else { 'OK' }
        })
    }

    # --- Client certificates (KeyCredentials of type AsymmetricX509Cert) ---
    foreach ($cert in ($app.KeyCredentials | Where-Object { $_.Type -eq 'AsymmetricX509Cert' })) {
        $endDate = $cert.EndDateTime
        if (-not $endDate) { continue }

        $isExpired = $endDate -lt $now
        $daysLeft  = [math]::Ceiling(($endDate - $now).TotalDays)

        if ($isExpired -and -not $IncludeExpired) { continue }
        if ($cutoffDate -and (-not $isExpired) -and $endDate -gt $cutoffDate) { continue }

        $results.Add([PSCustomObject]@{
            AppDisplayName = $app.DisplayName
            AppId          = $app.AppId
            Type           = 'Certificate'
            CredentialName = if ($cert.DisplayName) { $cert.DisplayName } else { '(unnamed)' }
            KeyId          = $cert.KeyId
            ExpirationDate = $endDate.ToString('yyyy-MM-dd')
            DaysLeft       = $daysLeft
            Status         = if ($isExpired) { 'Expired' }
                             elseif ($daysLeft -le 30) { 'Critical' }
                             elseif ($daysLeft -le 90) { 'Warning' }
                             else { 'OK' }
        })
    }
}

# ============================================================================
# Display results
# ============================================================================

if ($results.Count -eq 0) {
    Write-Host 'No credentials found matching the filter criteria.' -ForegroundColor Yellow
}
else {
    $sortedResults = $results | Sort-Object {
        # Sort non-expired entries ascending by days left; expired entries last
        if ($_.Status -eq 'Expired') { [int]::MaxValue } else { $_.DaysLeft }
    }

    Write-Host "Found $($results.Count) credential(s):" -ForegroundColor Cyan
    Write-Host ''

    $header = '{0,-40} {1,-14} {2,-13} {3,-30} {4,-12} {5}' -f `
        'App Display Name', 'App ID (short)', 'Type', 'Credential Name', 'Expires', 'Days Left'
    Write-Host $header -ForegroundColor White
    Write-Host ('-' * 120) -ForegroundColor DarkGray

    foreach ($row in $sortedResults) {
        $color = switch ($row.Status) {
            'Expired'  { 'Red'    }
            'Critical' { 'Red'    }
            'Warning'  { 'Yellow' }
            default    { 'Green'  }
        }

        $appNameDisplay = if ($row.AppDisplayName.Length -gt 40) {
            $row.AppDisplayName.Substring(0, 37) + '...'
        } else { $row.AppDisplayName }

        $credNameDisplay = if ($row.CredentialName.Length -gt 30) {
            $row.CredentialName.Substring(0, 27) + '...'
        } else { $row.CredentialName }

        $daysDisplay = if ($row.DaysLeft -lt 0) {
            "EXPIRED ($([math]::Abs($row.DaysLeft))d ago)"
        } else {
            "$($row.DaysLeft) days"
        }

        $line = '{0,-40} {1,-14} {2,-13} {3,-30} {4,-12} {5}' -f `
            $appNameDisplay,
            $row.AppId.Substring(0, [Math]::Min(14, $row.AppId.Length)),
            $row.Type,
            $credNameDisplay,
            $row.ExpirationDate,
            $daysDisplay

        Write-Host $line -ForegroundColor $color
    }

    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    $cntExpired  = @($results | Where-Object { $_.Status -eq 'Expired'  }).Count
    $cntCritical = @($results | Where-Object { $_.Status -eq 'Critical' }).Count
    $cntWarning  = @($results | Where-Object { $_.Status -eq 'Warning'  }).Count
    $cntOk       = @($results | Where-Object { $_.Status -eq 'OK'       }).Count

    if ($cntExpired  -gt 0) { Write-Host "  Expired  : $cntExpired"  -ForegroundColor Red    }
    if ($cntCritical -gt 0) { Write-Host "  Critical : $cntCritical" -ForegroundColor Red    }
    if ($cntWarning  -gt 0) { Write-Host "  Warning  : $cntWarning"  -ForegroundColor Yellow }
    if ($cntOk       -gt 0) { Write-Host "  OK       : $cntOk"       -ForegroundColor Green  }
}

# ============================================================================
# CSV export
# ============================================================================

if ($ExportCsv -and $results.Count -gt 0) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath   = Join-Path $exportOutputDir "ClientCredentials-Expiration-$timestamp.csv"

    $results |
        Sort-Object ExpirationDate |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host "Results exported to: $csvPath" -ForegroundColor Green
}
