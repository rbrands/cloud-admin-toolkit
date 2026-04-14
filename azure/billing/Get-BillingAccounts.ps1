<#
.SYNOPSIS
    Lists all Azure Billing Accounts accessible to the current user.

.DESCRIPTION
    Retrieves all Billing Accounts via the Az.Billing module and displays
    key properties: account name, display name, agreement type, and status.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Get-BillingAccounts.<Name>.json from the script directory)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Get-BillingAccounts.ps1

.EXAMPLE
    .\Get-BillingAccounts.ps1 -ConfigName prod

.NOTES
    Required Azure permission:
      Microsoft.Billing/billingAccounts/read
    Prerequisites:
      Az.Billing module  (run .\shared\Install-Prerequisites.ps1)
    Authentication:
      Run .\shared\Connect-AzToolkit.ps1 before executing this script.
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

    # Optional filter: only show accounts whose display name contains this string.
    [Parameter(Mandatory = $false)]
    [string]$DisplayNameFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name $ConfigName `
    -ConfigDir $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix 'Get-BillingAccounts'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $filterValue = $config.PSObject.Properties['filter']?.Value
    if (-not $DisplayNameFilter -and $null -ne $filterValue) {
        $DisplayNameFilter = $filterValue.PSObject.Properties['displayNameFilter']?.Value
    }
}

# --- Retrieve Billing Accounts ---
Write-Host "=== Get-BillingAccounts ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Retrieving billing accounts..." -ForegroundColor Yellow

$accounts = Get-AzBillingAccount -IncludeAddress

if (-not $accounts -or $accounts.Count -eq 0) {
    Write-Host "No billing accounts found." -ForegroundColor Yellow
    return
}

# --- Optional filter ---
if ($DisplayNameFilter) {
    Write-Host "Applying display name filter: '$DisplayNameFilter'" -ForegroundColor Yellow
    $accounts = $accounts | Where-Object { $_.DisplayName -like "*$DisplayNameFilter*" }
}

Write-Host "Found $($accounts.Count) billing account(s)." -ForegroundColor Green
Write-Host ""

# --- Output with Billing Profiles and Subscriptions ---
foreach ($account in $accounts) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "ACCOUNT: $($account.DisplayName)" -ForegroundColor Cyan
    Write-Host "Name           : $($account.Name)" -ForegroundColor Gray
    Write-Host "Agreement Type : $($account.AgreementType)" -ForegroundColor Gray
    Write-Host "Account Status : $($account.AccountStatus)" -ForegroundColor Gray

    # --- Billing Profiles ---
    $profiles = Get-AzBillingProfile -BillingAccountName $account.Name -ErrorAction SilentlyContinue
    if ($profiles) {
        foreach ($profile in $profiles) {
            Write-Host ""
            Write-Host "  BILLING PROFILE: $($profile.DisplayName)" -ForegroundColor Green
            Write-Host "  Status: $($profile.Status) | Currency: $($profile.Currency)"

            # --- Subscriptions via REST API (cmdlet does not return all) ---
            $subsResponse = Invoke-AzRestMethod `
                -Path "/providers/Microsoft.Billing/billingAccounts/$($account.Name)/billingSubscriptions?api-version=2020-05-01" `
                -Method GET
            $subsJson = ($subsResponse.Content | ConvertFrom-Json).value

            if ($subsJson) {
                $profileSubs = $subsJson |
                    Where-Object { $_.properties.billingProfileId -like "*$($profile.Name)*" }

                if ($profileSubs) {
                    $profileSubs |
                        Select-Object `
                            @{ N = 'Subscription'; E = { $_.properties.displayName } },
                            @{ N = 'SubId';        E = { $_.properties.subscriptionId } },
                            @{ N = 'Status';       E = { $_.properties.subscriptionStatus } } |
                        Format-Table -AutoSize
                }
                else {
                    Write-Host "  (no subscriptions for this billing profile)" -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host "  (no subscriptions)" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "  (no billing profiles or insufficient access)" -ForegroundColor DarkGray
    }

    Write-Host ""
}
