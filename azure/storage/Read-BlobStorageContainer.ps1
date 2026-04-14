<#
.SYNOPSIS
    Downloads all blobs from an Azure Blob Storage container to a local directory.

.DESCRIPTION
    Connects to an Azure Storage Account and downloads all blobs from the
    specified container to a local directory. The virtual directory structure
    embedded in blob names is preserved as subdirectories under the output folder.

    Two authentication modes are supported:

    1. Azure AD identity (default, -UseStorageKey $false)
       Requires the 'Storage Blob Data Reader' role on the storage account
       or container. Being Owner/Contributor on the subscription is NOT
       sufficient – the data-plane role must be assigned explicitly.

    2. Storage Account Key (-UseStorageKey)
       Retrieves the account key via ARM using the current Azure AD identity.
       Requires the 'Microsoft.Storage/storageAccounts/listKeys/action'
       permission, which Owner and Contributor have by default.
       Also requires -ResourceGroupName (or storage.resourceGroupName in config).

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Read-BlobStorageContainer.<Name>.json from the script directory)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files and the downloads folder must not be committed to the
    repository (both are excluded via .gitignore).

.EXAMPLE
    .\Read-BlobStorageContainer.ps1 -StorageAccountName mystorageaccount -ContainerName mycontainer

.EXAMPLE
    .\Read-BlobStorageContainer.ps1 -ConfigName prod

.NOTES
    Required Azure permissions:
      Azure AD mode  : Storage Blob Data Reader on the storage account or container
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

    # Name of the blob container to read.
    [Parameter(Mandatory = $false)]
    [string]$ContainerName,

    # Resource group of the storage account.
    # Required when -UseStorageKey is set and not provided via config.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # When set, authenticates using the storage account key instead of an Azure AD identity.
    # Useful when you have Owner/Contributor on the subscription but lack the
    # 'Storage Blob Data Reader' data-plane role.
    [Parameter(Mandatory = $false)]
    [switch]$UseStorageKey,

    # Local directory to write the downloaded blobs to.
    # Defaults to .\downloads\<StorageAccountName>\<ContainerName> relative to the script.
    [Parameter(Mandatory = $false)]
    [string]$LocalPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Read-BlobStorageContainer'
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

    $outputValue = $config.PSObject.Properties['output']?.Value
    if ($null -ne $outputValue -and -not $LocalPath) {
        $LocalPath = $outputValue.PSObject.Properties['localPath']?.Value
    }
}

# --- Validate required parameters ---
if (-not $StorageAccountName) {
    throw 'StorageAccountName is required. Provide it as a parameter or via the config file (storage.storageAccountName).'
}
if (-not $ContainerName) {
    throw 'ContainerName is required. Provide it as a parameter or via the config file (storage.containerName).'
}

# --- Set Azure subscription context ---
$null = Set-ToolkitAzContext -Config $config -SubscriptionId $SubscriptionId

# --- Resolve local output path ---
if (-not $LocalPath) {
    $LocalPath = Join-Path $PSScriptRoot "downloads\$StorageAccountName\$ContainerName"
}

# --- Create output directory if it does not yet exist ---
if (-not (Test-Path $LocalPath)) {
    $null = New-Item -ItemType Directory -Path $LocalPath -Force
    Write-Host "Created output directory: $LocalPath" -ForegroundColor Yellow
}

Write-Host "=== Read-BlobStorageContainer ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Storage Account : $StorageAccountName" -ForegroundColor Yellow
Write-Host "Container       : $ContainerName"       -ForegroundColor Yellow
Write-Host "Local path      : $LocalPath"           -ForegroundColor Yellow
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

# --- List blobs ---
Write-Host "Listing blobs in container '$ContainerName'..." -ForegroundColor Yellow
$blobs = @(Get-AzStorageBlob -Container $ContainerName -Context $storageContext)

if ($blobs.Count -eq 0) {
    Write-Host "No blobs found in container '$ContainerName'." -ForegroundColor Yellow
    return
}

Write-Host "Found $($blobs.Count) blob(s). Starting download..." -ForegroundColor Green
Write-Host ""

$successCount = 0
$errorCount   = 0

foreach ($blob in $blobs) {
    $blobName    = $blob.Name
    $destination = Join-Path $LocalPath $blobName

    # Preserve virtual directory structure embedded in the blob name
    $destinationDir = Split-Path $destination -Parent
    if (-not (Test-Path $destinationDir)) {
        $null = New-Item -ItemType Directory -Path $destinationDir -Force
    }

    try {
        Write-Host "  Downloading: $blobName" -ForegroundColor Yellow
        $null = Get-AzStorageBlobContent `
            -Container   $ContainerName `
            -Blob        $blobName `
            -Destination $destination `
            -Context     $storageContext `
            -Force
        $successCount++
        Write-Host "  -> OK: $destination" -ForegroundColor Green
    }
    catch {
        $errorCount++
        Write-Host "  ERROR downloading '$blobName': $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Download complete ===" -ForegroundColor Cyan
Write-Host "Success : $successCount" -ForegroundColor Green
if ($errorCount -gt 0) {
    Write-Host "Errors  : $errorCount" -ForegroundColor Red
}
else {
    Write-Host "Errors  : 0" -ForegroundColor Green
}
Write-Host "Files saved to: $LocalPath" -ForegroundColor Cyan
