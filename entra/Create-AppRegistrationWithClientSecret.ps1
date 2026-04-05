<#
.SYNOPSIS
    Creates an Entra ID App Registration with a client secret credential.

.DESCRIPTION
    Creates an App Registration and matching Enterprise Application (service principal),
    generates a client secret, and outputs the secret value to the console and clipboard.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Create-AppRegistrationWithClientSecret.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    Authentication can be handled in two explicit ways:
    - Pre-connect manually via Connect-MgGraph before running the script, or
    - Use -ConnectGraph to let this script call Connect-MgGraph explicitly.

    SECURITY NOTE: The client secret value is shown only once after creation.
    Copy it immediately – it cannot be retrieved again.

.EXAMPLE
    .\Create-AppRegistrationWithClientSecret.ps1 -ConfigName prod

.EXAMPLE
    .\Create-AppRegistrationWithClientSecret.ps1 -AppRegistrationName 'my-app-prd' -ServiceNowTicket 'RITM1234567'

.EXAMPLE
    .\Create-AppRegistrationWithClientSecret.ps1 -ConfigName prod -ConnectGraph
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

    # Display name for the new App Registration.
    [Parameter(Mandatory = $false)]
    [string]$AppRegistrationName,

    # Optional notes field, typically used for ticket references.
    [Parameter(Mandatory = $false)]
    [string]$ServiceNowTicket,

    # Display name for the client secret.
    [Parameter(Mandatory = $false)]
    [string]$SecretDisplayName = 'client-secret',

    # Client secret validity in years.
    [Parameter(Mandatory = $false)]
    [int]$ValidityYears = 1,

    # Explicitly connect to Microsoft Graph from this script.
    [Parameter(Mandatory = $false)]
    [switch]$ConnectGraph,

    # Optional tenant ID used for Connect-MgGraph.
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    # Graph scopes requested when -ConnectGraph is used.
    [Parameter(Mandatory = $false)]
    [string[]]$GraphScopes = @('Application.ReadWrite.All'),

    # Use device authentication flow for Connect-MgGraph.
    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Create-AppRegistrationWithClientSecret'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $PSBoundParameters.ContainsKey('AppRegistrationName') -and $null -ne $config -and $config.appRegistrationName) {
    $AppRegistrationName = [string]$config.appRegistrationName
}

if (-not $PSBoundParameters.ContainsKey('ServiceNowTicket') -and $null -ne $config -and
    $config.PSObject.Properties['serviceNowTicket']) {
    $ServiceNowTicket = [string]$config.serviceNowTicket
}

if (-not $PSBoundParameters.ContainsKey('SecretDisplayName') -and $null -ne $config -and
    $config.PSObject.Properties['secretDisplayName']) {
    $SecretDisplayName = [string]$config.secretDisplayName
}

if (-not $PSBoundParameters.ContainsKey('ValidityYears') -and $null -ne $config -and
    $config.PSObject.Properties['validityYears']) {
    $ValidityYears = [int]$config.validityYears
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and $null -ne $config -and $config.tenantId) {
    $TenantId = [string]$config.tenantId
}

if (-not $PSBoundParameters.ContainsKey('GraphScopes') -and $null -ne $config -and $config.graphScopes) {
    $GraphScopes = [string[]]$config.graphScopes
}

if (-not $ConnectGraph.IsPresent -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['connectGraph'] -and
    $config.auth.connectGraph -eq $true) {
    $ConnectGraph = $true
}

if (-not $UseDeviceAuthentication.IsPresent -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['useDeviceAuthentication'] -and
    $config.auth.useDeviceAuthentication -eq $true) {
    $UseDeviceAuthentication = $true
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $AppRegistrationName) {
    Write-Host "No app registration name provided. Specify -AppRegistrationName or set appRegistrationName in the config file." -ForegroundColor Red
    exit 1
}

if ($ValidityYears -lt 1) {
    Write-Host "ValidityYears must be greater than or equal to 1." -ForegroundColor Red
    exit 1
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host "=== Create-AppRegistrationWithClientSecret ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config           : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "App name         : $AppRegistrationName" -ForegroundColor Gray
Write-Host "Secret name      : $SecretDisplayName" -ForegroundColor Gray
Write-Host "Validity (years) : $ValidityYears" -ForegroundColor Gray
Write-Host "Graph connect    : $(if ($ConnectGraph) { 'Connect in script' } else { 'Use existing session' })" -ForegroundColor Gray
Write-Host ""

try {
    if ($ConnectGraph) {
        Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Yellow

        $graphConnectParams = @{
            Scopes      = $GraphScopes
            ErrorAction = 'Stop'
            NoWelcome   = $true
        }

        if ($TenantId) {
            $graphConnectParams.TenantId = $TenantId
        }
        if ($UseDeviceAuthentication) {
            $graphConnectParams.UseDeviceAuthentication = $true
        }

        Connect-MgGraph @graphConnectParams
    }

    # Verify Microsoft Graph context
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context -or -not $context.TenantId) {
        throw 'No active Microsoft Graph tenant context. Run Connect-MgGraph first, or run this script with -ConnectGraph.'
    }

    # Create app registration
    Write-Host "Creating App Registration '$AppRegistrationName'..." -ForegroundColor Yellow
    $appParams = @{ DisplayName = $AppRegistrationName }
    if ($ServiceNowTicket) {
        $appParams.Notes = $ServiceNowTicket
    }
    $app = New-MgApplication @appParams

    # Create enterprise application (service principal)
    Write-Host 'Creating Enterprise Application (service principal)...' -ForegroundColor Yellow
    $null = New-MgServicePrincipal -AppId $app.AppId -Tags @('WindowsAzureActiveDirectoryIntegratedApp')

    # Add client secret
    Write-Host 'Adding client secret...' -ForegroundColor Yellow
    $secretEndDate = (Get-Date).AddYears($ValidityYears)

    $passwordCredential = @{
        DisplayName = $SecretDisplayName
        EndDateTime = $secretEndDate
    }

    $secretResult = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCredential

    Write-Host "  Secret ID  : $($secretResult.KeyId)" -ForegroundColor Green
    Write-Host "  Expires    : $($secretResult.EndDateTime)" -ForegroundColor Green

    # Output result and copy summary to clipboard
    $result = [PSCustomObject]@{
        AppName       = $app.DisplayName
        ClientId      = $app.AppId
        TenantId      = $context.TenantId
        SecretId      = $secretResult.KeyId
        SecretExpires = $secretResult.EndDateTime
        ClientSecret  = $secretResult.SecretText
    }

    Write-Host "`nResult:" -ForegroundColor Cyan
    $result | Format-List

    $clipboardText = @(
        "$($result.AppName)",
        "Client ID     : $($result.ClientId)",
        "Tenant ID     : $($result.TenantId)",
        "Secret ID     : $($result.SecretId)",
        "Secret Expires: $($result.SecretExpires)",
        "Client Secret : $($result.ClientSecret)"
    ) -join [Environment]::NewLine

    Set-Clipboard -Value $clipboardText
    Write-Host 'Copied summary to clipboard.' -ForegroundColor Green

    Write-Host ''
    Write-Host 'IMPORTANT SECURITY NOTICE:' -ForegroundColor Red
    Write-Host '  The client secret value is shown only once. It CANNOT be retrieved again.' -ForegroundColor Red
    Write-Host '  Store it securely (e.g. Azure Key Vault) and NEVER commit it to source control.' -ForegroundColor Red
}
catch {
    Write-Host 'ERROR: Failed to create App Registration with client secret.' -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
