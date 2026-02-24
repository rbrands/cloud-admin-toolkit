<#
.SYNOPSIS
    Connects to Azure and sets a deterministic default subscription context.

.DESCRIPTION
    Supports:
    - -ConfigPath  (explicit path to JSON file)
    - -ConfigName  (loads Connect-AzToolkit.<name>.json from script directory)

    Concrete config files must not be committed to the repository.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$DefaultSubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name $ConfigName `
    -ScriptRoot $PSScriptRoot `
    -Prefix 'Connect-AzToolkit'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $ctxValue  = $config.PSObject.Properties['context']?.Value
    $authValue = $config.PSObject.Properties['auth']?.Value

    if (-not $TenantId -and $null -ne $ctxValue) {
        $TenantId = $ctxValue.tenantId
    }
    if (-not $DefaultSubscriptionId -and $null -ne $ctxValue) {
        $DefaultSubscriptionId = $ctxValue.PSObject.Properties['subscriptionId']?.Value
        if (-not $DefaultSubscriptionId) {
            $DefaultSubscriptionId = $ctxValue.PSObject.Properties['defaultSubscriptionId']?.Value
        }
    }
    if (-not $UseDeviceAuthentication.IsPresent -and $null -ne $authValue -and $authValue.useDeviceAuthentication) {
        $UseDeviceAuthentication = $true
    }
}

# --- Basic module check ---
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module not found. Run Install-Prerequisites.ps1 first."
}

Write-Host "=== Connect-AzToolkit ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Using config: $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host ""

# --- Connect ---
$connectParams = @{
    ErrorAction = 'Stop'
}

if ($TenantId) { $connectParams.Tenant = $TenantId }
if ($DefaultSubscriptionId) { $connectParams.Subscription = $DefaultSubscriptionId }
if ($UseDeviceAuthentication) { $connectParams.UseDeviceAuthentication = $true }

Write-Host "Connecting to Azure..." -ForegroundColor Cyan
$null = Connect-AzAccount @connectParams

# --- Set deterministic subscription context ---
$subs = Get-AzSubscription -ErrorAction Stop

if ($DefaultSubscriptionId) {
    Set-ToolkitAzContext -SubscriptionId $DefaultSubscriptionId | Out-Null
}
elseif ($null -ne $config) {
    Set-ToolkitAzContext -Config $config | Out-Null
}
elseif ($subs.Count -eq 1) {
    Write-Host "Only one subscription found. Setting context automatically." -ForegroundColor Yellow
    $null = Set-AzContext -SubscriptionId $subs[0].Id -ErrorAction Stop
}
else {
    $available = ($subs | Select-Object -ExpandProperty Id) -join ", "
    throw "Multiple subscriptions detected. Provide DefaultSubscriptionId. Available: $available"
}

$ctx = Get-AzContext
Write-Host ("Connected. Context set to: {0} ({1})" -f $ctx.Subscription.Name, $ctx.Subscription.Id) -ForegroundColor Green

return $ctx
