<#
.SYNOPSIS
    Creates an Entra ID App Registration with a client secret and assigns an Azure RBAC role,
    ready for use with GitHub Actions (azure/login@v2).

.DESCRIPTION
    Creates an App Registration and matching Enterprise Application (service principal),
    generates a client secret, assigns an Azure RBAC role on a resource group,
    and exports the credentials as a JSON file in the format required by GitHub Actions.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Create-ServicePrincipalForDeployment.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    Authentication can be handled in two explicit ways:
    - Pre-connect manually via Connect-MgGraph / Connect-AzAccount before running the script, or
    - Use -ConnectGraph / -ConnectAzure to let this script connect explicitly.

    NOTE: Add the following to your .gitignore:
    # Credentials/*.github-credentials.json

.EXAMPLE
    .\Create-ServicePrincipalForDeployment.ps1 -ConfigName brands-advisory

.EXAMPLE
    .\Create-ServicePrincipalForDeployment.ps1 -AppRegistrationName 'sp-myapp-github' -SubscriptionId '<sub-id>' -ResourceGroupName 'rg-myapp'

.EXAMPLE
    .\Create-ServicePrincipalForDeployment.ps1 -ConfigName brands-advisory -ConnectGraph -ConnectAzure
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

    # Display name for the new App Registration, e.g. "sp-brands-advisory-github".
    [Parameter(Mandatory = $false)]
    [string]$AppRegistrationName,

    # Optional notes field, typically used for ticket references.
    [Parameter(Mandatory = $false)]
    [string]$ServiceNowTicket,

    # Azure Subscription ID for RBAC role assignment.
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    # Resource group name to assign the role on.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # Azure RBAC role to assign.
    [Parameter(Mandatory = $false)]
    [string]$Role = 'Contributor',

    # Client secret validity in months.
    [Parameter(Mandatory = $false)]
    [int]$SecretValidityMonths = 24,

    # Output directory for the credentials JSON file.
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\Credentials',

    # Explicitly connect to Microsoft Graph from this script.
    [Parameter(Mandatory = $false)]
    [switch]$ConnectGraph,

    # Explicitly connect to Azure (Connect-AzAccount) from this script.
    [Parameter(Mandatory = $false)]
    [switch]$ConnectAzure,

    # Optional tenant ID used for Connect-MgGraph and Connect-AzAccount.
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
    -Prefix       'Create-ServicePrincipalForDeployment'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $PSBoundParameters.ContainsKey('AppRegistrationName') -and $null -ne $config -and $config.appRegistrationName) {
    $AppRegistrationName = [string]$config.appRegistrationName
}

if (-not $PSBoundParameters.ContainsKey('ServiceNowTicket') -and $null -ne $config -and
    $config.PSObject.Properties['serviceNowTicket']) {
    $ServiceNowTicket = [string]$config.serviceNowTicket
}

if (-not $PSBoundParameters.ContainsKey('SubscriptionId') -and $null -ne $config -and
    $config.PSObject.Properties['subscriptionId']) {
    $SubscriptionId = [string]$config.subscriptionId
}

if (-not $PSBoundParameters.ContainsKey('ResourceGroupName') -and $null -ne $config -and
    $config.PSObject.Properties['resourceGroupName']) {
    $ResourceGroupName = [string]$config.resourceGroupName
}

if (-not $PSBoundParameters.ContainsKey('Role') -and $null -ne $config -and
    $config.PSObject.Properties['role']) {
    $Role = [string]$config.role
}

if (-not $PSBoundParameters.ContainsKey('SecretValidityMonths') -and $null -ne $config -and
    $config.PSObject.Properties['secretValidityMonths']) {
    $SecretValidityMonths = [int]$config.secretValidityMonths
}

if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $null -ne $config -and $config.outputPath) {
    $OutputPath = [string]$config.outputPath
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and $null -ne $config -and
    $config.PSObject.Properties['tenantId']) {
    $TenantId = [string]$config.tenantId
}

# Fall back to the current Az context tenant if not explicitly configured.
if (-not $TenantId) {
    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if ($azCtx -and $azCtx.Tenant.Id) {
        $TenantId = $azCtx.Tenant.Id
    }
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

if (-not $ConnectAzure.IsPresent -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['connectAzure'] -and
    $config.auth.connectAzure -eq $true) {
    $ConnectAzure = $true
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

# Fall back to the current Az context subscription if not explicitly configured.
if (-not $SubscriptionId) {
    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if ($azCtx -and $azCtx.Subscription.Id) {
        $SubscriptionId = $azCtx.Subscription.Id
        Write-Host "SubscriptionId not configured – using current Az context: $SubscriptionId" -ForegroundColor Yellow
    }
}

if (-not $SubscriptionId) {
    Write-Host "No subscription ID available. Specify -SubscriptionId, set subscriptionId in the config file, or connect via Connect-AzToolkit.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not $ResourceGroupName) {
    Write-Host "No resource group name provided. Specify -ResourceGroupName or set resourceGroupName in the config file." -ForegroundColor Red
    exit 1
}

if ($SecretValidityMonths -lt 1) {
    Write-Host "SecretValidityMonths must be greater than or equal to 1." -ForegroundColor Red
    exit 1
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host "=== Create-ServicePrincipalForDeployment ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config           : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "App name         : $AppRegistrationName" -ForegroundColor Gray
Write-Host "Subscription     : $SubscriptionId" -ForegroundColor Gray
Write-Host "Resource group   : $ResourceGroupName" -ForegroundColor Gray
Write-Host "Role             : $Role" -ForegroundColor Gray
Write-Host "Secret validity  : $SecretValidityMonths months" -ForegroundColor Gray
Write-Host "Output path      : $OutputPath" -ForegroundColor Gray
Write-Host "Graph connect    : $(if ($ConnectGraph) { 'Connect in script' } else { 'Use existing session' })" -ForegroundColor Gray
Write-Host "Azure connect    : $(if ($ConnectAzure) { 'Connect in script' } else { 'Use existing session' })" -ForegroundColor Gray
Write-Host ""

$credBaseName = $AppRegistrationName -replace '[^a-zA-Z0-9-_]', '_'
$credFileName = "$credBaseName.github-credentials.json"

try {
    # ── Connect to Microsoft Graph ─────────────────────────────────────────────

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

    # ── Connect to Azure ───────────────────────────────────────────────────────

    if ($ConnectAzure) {
        Write-Host 'Connecting to Azure...' -ForegroundColor Yellow

        $azConnectParams = @{ ErrorAction = 'Stop' }
        if ($TenantId) {
            $azConnectParams.TenantId = $TenantId
        }
        if ($SubscriptionId) {
            $azConnectParams.SubscriptionId = $SubscriptionId
        }

        Connect-AzAccount @azConnectParams | Out-Null
    }

    # ── Create App Registration ────────────────────────────────────────────────

    Write-Host "Creating App Registration '$AppRegistrationName'..." -ForegroundColor Yellow
    $appParams = @{ DisplayName = $AppRegistrationName }
    if ($ServiceNowTicket) {
        $appParams.Notes = $ServiceNowTicket
    }
    $app = New-MgApplication @appParams
    Write-Host "  App ID     : $($app.AppId)" -ForegroundColor Green
    Write-Host "  Object ID  : $($app.Id)" -ForegroundColor Green

    # ── Create Enterprise Application (Service Principal) ─────────────────────

    Write-Host 'Creating Enterprise Application (service principal)...' -ForegroundColor Yellow
    $sp = New-MgServicePrincipal -AppId $app.AppId -Tags @('WindowsAzureActiveDirectoryIntegratedApp')
    Write-Host "  SP Object ID: $($sp.Id)" -ForegroundColor Green

    # ── Create Client Secret ───────────────────────────────────────────────────

    Write-Host 'Adding client secret...' -ForegroundColor Yellow
    $secretEndDate = (Get-Date).AddMonths($SecretValidityMonths)

    $passwordCredential = @{
        DisplayName = 'github-actions'
        EndDateTime = $secretEndDate
    }

    $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCredential
    Write-Host "  Secret ID  : $($secret.KeyId)" -ForegroundColor Green
    Write-Host "  Expires    : $($secret.EndDateTime)" -ForegroundColor Green

    # ── Assign Azure RBAC Role ─────────────────────────────────────────────────

    Write-Host "Assigning role '$Role' on resource group '$ResourceGroupName'..." -ForegroundColor Yellow

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $assigned = $false
    $maxRetries = 5
    $retryDelaySeconds = 10

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            New-AzRoleAssignment `
                -ObjectId           $sp.Id `
                -RoleDefinitionName $Role `
                -Scope              $scope `
                -ErrorAction        Stop | Out-Null

            $assigned = $true
            Write-Host "  Role assigned successfully (attempt $attempt)." -ForegroundColor Green
            break
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Host "  Attempt $attempt failed (SP propagation delay). Retrying in $retryDelaySeconds s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $retryDelaySeconds
            }
            else {
                throw "Role assignment failed after $maxRetries attempts: $($_.Exception.Message)"
            }
        }
    }

    if (-not $assigned) {
        throw "Role assignment could not be completed."
    }

    # ── Build GitHub Actions Credentials JSON ──────────────────────────────────

    Write-Host 'Building GitHub Actions credentials JSON...' -ForegroundColor Yellow

    $githubJson = [ordered]@{
        clientId                         = $app.AppId
        clientSecret                     = $secret.SecretText
        subscriptionId                   = $SubscriptionId
        tenantId                         = $context.TenantId
        activeDirectoryEndpointUrl       = 'https://login.microsoftonline.com'
        resourceManagerEndpointUrl       = 'https://management.azure.com/'
        activeDirectoryGraphResourceId   = 'https://graph.windows.net/'
        sqlManagementEndpointUrl         = 'https://management.core.windows.net:8443/'
        galleryEndpointUrl               = 'https://gallery.azure.com/'
        managementEndpointUrl            = 'https://management.core.windows.net/'
    } | ConvertTo-Json

    # ── Save credentials file ──────────────────────────────────────────────────

    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if (-not (Test-Path $OutputPath)) {
        Write-Host "Creating output directory: $OutputPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $credFilePath = [System.IO.Path]::GetFullPath((Join-Path $OutputPath $credFileName))
    Set-Content -LiteralPath $credFilePath -Value $githubJson -Encoding UTF8
    Write-Host "  Saved: $credFilePath" -ForegroundColor Green
    Write-Host "  WARNING: NEVER commit this file to source control." -ForegroundColor Red

    # ── Output result ──────────────────────────────────────────────────────────

    $result = [PSCustomObject]@{
        AppName         = $app.DisplayName
        ClientId        = $app.AppId
        TenantId        = $context.TenantId
        SubscriptionId  = $SubscriptionId
        ResourceGroup   = $ResourceGroupName
        Role            = $Role
        SecretExpires   = $secret.EndDateTime
        CredentialsFile = $credFilePath
    }

    Write-Host "`nResult:" -ForegroundColor Cyan
    $result | Format-List

    Set-Clipboard -Value $githubJson
    Write-Host 'Copied GitHub Actions credentials JSON to clipboard.' -ForegroundColor Green

    Write-Host ''
    Write-Host 'IMPORTANT SECURITY NOTICE:' -ForegroundColor Red
    Write-Host '  The credentials JSON contains a client secret in plaintext.' -ForegroundColor Red
    Write-Host '  Store it securely and NEVER commit it to source control.' -ForegroundColor Red
    Write-Host '  Add *.github-credentials.json to .gitignore.' -ForegroundColor Red
    Write-Host '  Rotate the secret before it expires.' -ForegroundColor Red
}
catch {
    Write-Host 'ERROR: Failed to create service principal for deployment.' -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
