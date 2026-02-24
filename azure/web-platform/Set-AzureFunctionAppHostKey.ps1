<#
.SYNOPSIS
    Creates or updates a host key on an Azure Function App using Azure CLI.

.DESCRIPTION
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
if ($SubscriptionId) {
    Write-Host "Subscription:   $SubscriptionId" -ForegroundColor Cyan
} else {
    Write-Host 'Subscription:   (using current Azure CLI context)' -ForegroundColor Cyan
}
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "Function App:   $FunctionAppName"   -ForegroundColor Cyan
Write-Host "Host Key Name:  $HostKeyName"       -ForegroundColor Cyan
Write-Host ''

try {
    # Check if Azure CLI is available
    az version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI (az) is not installed or not in PATH. See: https://learn.microsoft.com/cli/azure/install-azure-cli'
    }

    # Check if logged in to Azure CLI
    Write-Host 'Checking Azure CLI login status...' -ForegroundColor Gray
    az account show 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to Azure CLI. Run 'az login' first."
    }

    # Set the subscription context only if explicitly provided
    if ($SubscriptionId) {
        Write-Host 'Setting Azure CLI subscription context...' -ForegroundColor Gray
        az account set --subscription $SubscriptionId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set subscription context '$SubscriptionId'. Ensure you have access."
        }
    }

    # Verify the Function App exists
    Write-Host "Verifying Function App '$FunctionAppName'..." -ForegroundColor Gray
    $functionAppJson = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Function App '$FunctionAppName' not found in resource group '$ResourceGroupName'."
    }

    $functionApp = $functionAppJson | ConvertFrom-Json
    Write-Host 'Found Function App:' -ForegroundColor Green
    Write-Host "  Name:           $($functionApp.name)"          -ForegroundColor Green
    Write-Host "  Resource Group: $($functionApp.resourceGroup)" -ForegroundColor Green
    Write-Host "  Location:       $($functionApp.location)"      -ForegroundColor Green
    Write-Host ''

    # Set the host key
    Write-Host "Setting host key '$HostKeyName'..." -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($HostKeyValue)) {
        Write-Host 'Using provided key value.' -ForegroundColor Gray
        az functionapp keys set --name $FunctionAppName --resource-group $ResourceGroupName `
            --key-type functionKeys --key-name $HostKeyName --key-value $HostKeyValue `
            --output json 2>&1 | Out-Null
    } else {
        Write-Host 'No value provided - Azure will auto-generate the key.' -ForegroundColor Gray
        az functionapp keys set --name $FunctionAppName --resource-group $ResourceGroupName `
            --key-type functionKeys --key-name $HostKeyName `
            --output json 2>&1 | Out-Null
    }

    # Retrieve and display the key
    Write-Host 'Retrieving key value...' -ForegroundColor Gray
    $listResult = az functionapp keys list --name $FunctionAppName --resource-group $ResourceGroupName --output json 2>&1

    Write-Host ''
    if ($listResult) {
        try {
            $jsonLines = $listResult | Where-Object { $_ -match '^\s*[\{\[]' -or $_ -match '^\s*"' -or $_ -match '^\s*\}' -or $_ -match '^\s*\]' }
            $jsonString = $jsonLines -join "`n"

            if ($jsonString) {
                $allKeys   = $jsonString | ConvertFrom-Json
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
            Write-Host "SUCCESS: Host key '$HostKeyName' has been set!" -ForegroundColor Green
            Write-Host "Note: Could not parse key value. Error: $($_.Exception.Message)" -ForegroundColor Gray
        }
    } else {
        Write-Host "SUCCESS: Host key '$HostKeyName' has been set!" -ForegroundColor Green
        Write-Host 'Note: No output received. Retrieve the key from the Azure Portal.' -ForegroundColor Yellow
    }

} catch {
    Write-Host 'ERROR: An unexpected error occurred!' -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)"       -ForegroundColor Red
    Write-Host "Stack: $($_.ScriptStackTrace)"         -ForegroundColor Red
    exit 1
}
