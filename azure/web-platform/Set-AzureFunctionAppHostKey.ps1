<#
.SYNOPSIS
    Creates or updates a host key on an Azure Function App using Az PowerShell (Invoke-AzRestMethod).

.DESCRIPTION
    Uses the Az PowerShell session established by Connect-AzToolkit.ps1 — no separate 'az login' required.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Set-AzureFunctionAppHostKey.<Name>.json from script directory)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Set-AzureFunctionAppHostKey.ps1 -ConfigName prod

.EXAMPLE
    .\Set-AzureFunctionAppHostKey.ps1 -SubscriptionId '<guid>' -ResourceGroupName 'my-rg' -FunctionAppName 'my-func' -HostKeyName 'server'

.NOTES
    Required Azure role (minimum): Website Contributor
    Scope: the target Function App or its Resource Group
    Required permission: Microsoft.Web/sites/host/functionkeys/write
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    # Directory to search for the config file. Defaults to the script directory.
    # Use this when config files are stored in a subdirectory.
    [Parameter(Mandatory = $false)]
    [string]$ConfigDir,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $false)]
    [string]$HostKeyName,

    # Optional: explicit key value. If omitted, Azure auto-generates the key.
    [Parameter(Mandatory = $false)]
    [string]$HostKeyValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name $ConfigName `
    -ConfigDir $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix 'Set-AzureFunctionAppHostKey'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $ctxValue  = $config.PSObject.Properties['context']?.Value
    $appValue  = $config.PSObject.Properties['functionApp']?.Value
    $keyValue  = $config.PSObject.Properties['hostKey']?.Value

    if (-not $SubscriptionId -and $null -ne $ctxValue) {
        $SubscriptionId = $ctxValue.PSObject.Properties['subscriptionId']?.Value
    }
    if (-not $ResourceGroupName -and $null -ne $appValue) {
        $ResourceGroupName = $appValue.PSObject.Properties['resourceGroupName']?.Value
    }
    if (-not $FunctionAppName -and $null -ne $appValue) {
        $FunctionAppName = $appValue.PSObject.Properties['name']?.Value
    }
    if (-not $HostKeyName -and $null -ne $keyValue) {
        $HostKeyName = $keyValue.PSObject.Properties['name']?.Value
    }
    if (-not $HostKeyValue -and $null -ne $keyValue) {
        $HostKeyValue = $keyValue.PSObject.Properties['value']?.Value
    }
}

# --- Validate required parameters ---
if (-not $ResourceGroupName) { throw 'ResourceGroupName is required.' }
if (-not $FunctionAppName)  { throw 'FunctionAppName is required.' }
if (-not $HostKeyName)      { throw 'HostKeyName is required.' }

Write-Host '=== Set-AzureFunctionAppHostKey ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Using config: $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host ''

try {
    # Verify Az PowerShell session is active
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) {
        throw "Not connected to Azure. Run Connect-AzToolkit.ps1 first."
    }

    # Set the subscription context only if explicitly provided
    if ($SubscriptionId) {
        Write-Host "Setting subscription context to '$SubscriptionId'..." -ForegroundColor Gray
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext -ErrorAction Stop
    }

    $effectiveSubscriptionId = $ctx.Subscription.Id

    Write-Host "Subscription:   $($ctx.Subscription.Name) ($effectiveSubscriptionId)" -ForegroundColor Cyan
    Write-Host "Resource Group: $ResourceGroupName"                                    -ForegroundColor Cyan
    Write-Host "Function App:   $FunctionAppName"                                      -ForegroundColor Cyan
    Write-Host "Host Key Name:  $HostKeyName"                                          -ForegroundColor Cyan
    Write-Host ''

    $apiVersion = '2022-03-01'
    $basePath   = "/subscriptions/$effectiveSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"

    # Verify the Function App exists
    Write-Host "Verifying Function App '$FunctionAppName'..." -ForegroundColor Gray
    $appResponse = Invoke-AzRestMethod -Method GET -Path "${basePath}?api-version=$apiVersion" -ErrorAction Stop
    if ($appResponse.StatusCode -ne 200) {
        throw "Function App '$FunctionAppName' not found in resource group '$ResourceGroupName'. Status: $($appResponse.StatusCode)"
    }

    $functionApp = $appResponse.Content | ConvertFrom-Json
    Write-Host 'Found Function App:' -ForegroundColor Green
    Write-Host "  Name:           $($functionApp.name)"                   -ForegroundColor Green
    Write-Host "  Resource Group: $($functionApp.properties.resourceGroup ?? $ResourceGroupName)" -ForegroundColor Green
    Write-Host "  Location:       $($functionApp.location)"               -ForegroundColor Green
    Write-Host ''

    # Set the host key via REST API
    Write-Host "Setting host key '$HostKeyName'..." -ForegroundColor Gray
    $keyPath = "${basePath}/host/default/functionKeys/${HostKeyName}?api-version=$apiVersion"
    if (-not [string]::IsNullOrWhiteSpace($HostKeyValue)) {
        Write-Host 'Using provided key value.' -ForegroundColor Gray
        $body = @{ properties = @{ value = $HostKeyValue } } | ConvertTo-Json -Compress
    } else {
        Write-Host 'No value provided - Azure will auto-generate the key.' -ForegroundColor Gray
        $body = '{ "properties": {} }'
    }
    $setResponse = Invoke-AzRestMethod -Method PUT -Path $keyPath -Payload $body -ErrorAction Stop
    if ($setResponse.StatusCode -notin @(200, 201)) {
        throw "Failed to set host key '$HostKeyName'. Status: $($setResponse.StatusCode). $($setResponse.Content)"
    }

    # Retrieve and display the key via REST API
    Write-Host 'Retrieving key value...' -ForegroundColor Gray
    $listResponse = Invoke-AzRestMethod -Method POST `
        -Path "${basePath}/host/default/listkeys?api-version=$apiVersion" `
        -Payload '{}' -ErrorAction Stop

    Write-Host ''
    if ($listResponse.StatusCode -eq 200) {
        $allKeys   = $listResponse.Content | ConvertFrom-Json
        $targetKey = $allKeys.functionKeys.PSObject.Properties | Where-Object { $_.Name -eq $HostKeyName }

        if ($targetKey) {
            Write-Host "SUCCESS: Host key '$HostKeyName' has been set!" -ForegroundColor Green
            Write-Host "Key Value: $($targetKey.Value)"                 -ForegroundColor Green
            Write-Host ''
            Write-Host 'IMPORTANT: Save this key value securely.' -ForegroundColor Yellow
        } else {
            Write-Host "SUCCESS: Host key '$HostKeyName' has been set!" -ForegroundColor Green
            Write-Host 'Note: Key not found in list response. Retrieve it from the Azure Portal.' -ForegroundColor Yellow
        }
    } else {
        Write-Host "SUCCESS: Host key '$HostKeyName' has been set!" -ForegroundColor Green
        Write-Host 'Note: Could not retrieve key value. Retrieve it from the Azure Portal.' -ForegroundColor Yellow
    }
} catch {
    throw "[$FunctionAppName / $ResourceGroupName] $_"
}
