<#
.SYNOPSIS
    Uploads all files from a local directory to an Azure Blob Storage container.

.DESCRIPTION
    Recursively enumerates all files under a local directory and uploads them
    to the specified blob container. The path relative to the source directory
    is used as the blob name, so the directory structure is preserved as virtual
    directories in the container.

    Existing blobs with the same name are overwritten.

    Two authentication modes are supported:

    1. Azure AD identity (default, -UseStorageKey $false)
       Requires the 'Storage Blob Data Contributor' role on the storage account
       or container. Being Owner/Contributor on the subscription is NOT
       sufficient – the data-plane role must be assigned explicitly.

    2. Storage Account Key (-UseStorageKey)
       Retrieves the account key via ARM using the current Azure AD identity.
       Requires the 'Microsoft.Storage/storageAccounts/listKeys/action'
       permission, which Owner and Contributor have by default.
       Also requires -ResourceGroupName (or storage.resourceGroupName in config).

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Write-BlobStorageContainer.<Name>.json from the script directory)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository
    (excluded via .gitignore).

.EXAMPLE
    .\Write-BlobStorageContainer.ps1 -StorageAccountName mystorageaccount -ContainerName mycontainer -LocalPath C:\export

.EXAMPLE
    .\Write-BlobStorageContainer.ps1 -ConfigName prod

.NOTES
    Required Azure permissions:
      Azure AD mode  : Storage Blob Data Contributor on the storage account or container
      Storage Key mode: Microsoft.Storage/storageAccounts/listKeys/action
                        (included in Owner and Contributor)
    Prerequisites:
      Az.Storage module  (run .\shared\Install-Prerequisites.ps1)
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

    # Optional. Overrides the subscription set by Connect-AzToolkit.ps1.
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    # Name of the Azure Storage Account.
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    # Name of the blob container to upload to.
    [Parameter(Mandatory = $false)]
    [string]$ContainerName,

    # Resource group of the storage account.
    # Required when -UseStorageKey is set and not provided via config.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # When set, authenticates using the storage account key instead of an Azure AD identity.
    # Useful when you have Owner/Contributor on the subscription but lack the
    # 'Storage Blob Data Contributor' data-plane role.
    [Parameter(Mandatory = $false)]
    [switch]$UseStorageKey,

    # Local directory whose contents are uploaded. Required.
    [Parameter(Mandatory = $false)]
    [string]$LocalPath,

    # Optional glob pattern to restrict which files are uploaded (e.g. '*.json').
    # Defaults to '*' (all files).
    [Parameter(Mandatory = $false)]
    [string]$Filter = '*'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Write-BlobStorageContainer'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $ctxValue = $config.PSObject.Properties['context']?.Value
    if ($null -ne $ctxValue -and -not $SubscriptionId) {
        $SubscriptionId = $ctxValue.PSObject.Properties['subscriptionId']?.Value
    }

    $storageValue = $config.PSObject.Properties['storage']?.Value
    if ($null -ne $storageValue) {
        if (-not $StorageAccountName) {
            $StorageAccountName = $storageValue.PSObject.Properties['storageAccountName']?.Value
        }
        if (-not $ContainerName) {
            $ContainerName = $storageValue.PSObject.Properties['containerName']?.Value
        }
        if (-not $ResourceGroupName) {
            $ResourceGroupName = $storageValue.PSObject.Properties['resourceGroupName']?.Value
        }
        if (-not $UseStorageKey) {
            $useKeyValue = $storageValue.PSObject.Properties['useStorageKey']?.Value
            if ($useKeyValue -eq $true) { $UseStorageKey = $true }
        }
    }

    $inputValue = $config.PSObject.Properties['input']?.Value
    if ($null -ne $inputValue) {
        if (-not $LocalPath) {
            $LocalPath = $inputValue.PSObject.Properties['localPath']?.Value
        }
        if ($Filter -eq '*') {
            $filterValue = $inputValue.PSObject.Properties['filter']?.Value
            if ($filterValue) { $Filter = $filterValue }
        }
    }
}

# --- Validate required parameters ---
if (-not $StorageAccountName) {
    throw 'StorageAccountName is required. Provide it as a parameter or via the config file (storage.storageAccountName).'
}
if (-not $ContainerName) {
    throw 'ContainerName is required. Provide it as a parameter or via the config file (storage.containerName).'
}
if (-not $LocalPath) {
    throw 'LocalPath is required. Provide it as a parameter or via the config file (input.localPath).'
}
if (-not (Test-Path $LocalPath)) {
    throw "LocalPath does not exist: $LocalPath"
}

# --- Set Azure subscription context ---
$null = Set-ToolkitAzContext -Config $config -SubscriptionId $SubscriptionId

Write-Host "=== Write-BlobStorageContainer ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Storage Account : $StorageAccountName" -ForegroundColor Yellow
Write-Host "Container       : $ContainerName"       -ForegroundColor Yellow
Write-Host "Local path      : $LocalPath"           -ForegroundColor Yellow
Write-Host "Filter          : $Filter"              -ForegroundColor Yellow
Write-Host ""

# --- Build storage context ---
if ($UseStorageKey) {
    if (-not $ResourceGroupName) {
        throw 'ResourceGroupName is required when -UseStorageKey is set. Provide it as a parameter or via the config file (storage.resourceGroupName).'
    }
    Write-Host "Auth mode       : Storage Account Key (ARM lookup)" -ForegroundColor Yellow
    $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $keys[0].Value
}
else {
    Write-Host "Auth mode       : Azure AD identity" -ForegroundColor Yellow
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
}

# --- Enumerate local files ---
$localRoot  = (Resolve-Path $LocalPath).Path
$files      = @(Get-ChildItem -Path $localRoot -Recurse -File -Filter $Filter)

if ($files.Count -eq 0) {
    Write-Host "No files found in '$LocalPath' matching filter '$Filter'." -ForegroundColor Yellow
    return
}

Write-Host "Found $($files.Count) file(s). Starting upload..." -ForegroundColor Green
Write-Host ""

$successCount = 0
$errorCount   = 0

foreach ($file in $files) {
    # Derive blob name from relative path, using forward slashes as separator
    $relativePath = $file.FullName.Substring($localRoot.Length).TrimStart('\', '/')
    $blobName     = $relativePath -replace '\\', '/'

    try {
        Write-Host "  Uploading: $blobName" -ForegroundColor Yellow
        $null = Set-AzStorageBlobContent `
            -File      $file.FullName `
            -Container $ContainerName `
            -Blob      $blobName `
            -Context   $storageContext `
            -Force
        $successCount++
        Write-Host "  -> OK" -ForegroundColor Green
    }
    catch {
        $errorCount++
        Write-Host "  ERROR uploading '$blobName': $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Upload complete ===" -ForegroundColor Cyan
Write-Host "Success : $successCount" -ForegroundColor Green
if ($errorCount -gt 0) {
    Write-Host "Errors  : $errorCount" -ForegroundColor Red
}
else {
    Write-Host "Errors  : 0" -ForegroundColor Green
}
