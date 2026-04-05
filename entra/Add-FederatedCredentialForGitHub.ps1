<#
.SYNOPSIS
    Adds an OIDC federated credential to an existing Entra ID App Registration for GitHub Actions.

.DESCRIPTION
    Adds a federated identity credential to an existing App Registration, enabling GitHub Actions
    to authenticate to Azure using OpenID Connect (OIDC) without a client secret.

    Supports branch, tag, environment, and pull_request entity types.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Add-FederatedCredentialForGitHub.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    Authentication can be handled in two explicit ways:
    - Pre-connect manually via Connect-MgGraph before running the script, or
    - Use -ConnectGraph to let this script call Connect-MgGraph explicitly.

.EXAMPLE
    .\Add-FederatedCredentialForGitHub.ps1 -ConfigName brands-advisory-cms-github

.EXAMPLE
    .\Add-FederatedCredentialForGitHub.ps1 -AppRegistrationName 'sp-myapp-github' -GitHubOrganization 'myorg' -GitHubRepository 'myrepo' -GitHubEntity branch -GitHubEntityValue main

.EXAMPLE
    .\Add-FederatedCredentialForGitHub.ps1 -ConfigName brands-advisory-cms-github -ConnectGraph
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

    # Display name of the existing App Registration to add the credential to.
    [Parameter(Mandatory = $false)]
    [string]$AppRegistrationName,

    # Optional: App Registration client ID to disambiguate when multiple apps share the same display name.
    [Parameter(Mandatory = $false)]
    [string]$AppId,

    # GitHub organization or user name, e.g. "brands-advisory".
    [Parameter(Mandatory = $false)]
    [string]$GitHubOrganization,

    # GitHub repository name, e.g. "brands-advisory-cms".
    [Parameter(Mandatory = $false)]
    [string]$GitHubRepository,

    # Entity type: branch, tag, environment, or pull_request.
    [Parameter(Mandatory = $false)]
    [ValidateSet('branch', 'tag', 'environment', 'pull_request')]
    [string]$GitHubEntity,

    # Entity value, e.g. "main" for a branch. Not used for pull_request.
    [Parameter(Mandatory = $false)]
    [string]$GitHubEntityValue,

    # Display name for the federated credential.
    # Defaults to "{GitHubOrganization}-{GitHubRepository}-{GitHubEntity}-{GitHubEntityValue}".
    [Parameter(Mandatory = $false)]
    [string]$CredentialName,

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
    -Prefix       'Add-FederatedCredentialForGitHub'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $PSBoundParameters.ContainsKey('AppRegistrationName') -and $null -ne $config -and
    $config.PSObject.Properties['appRegistrationName']) {
    $AppRegistrationName = [string]$config.appRegistrationName
}

if (-not $PSBoundParameters.ContainsKey('AppId') -and $null -ne $config -and
    $config.PSObject.Properties['appId']) {
    $AppId = [string]$config.appId
}

if (-not $PSBoundParameters.ContainsKey('GitHubOrganization') -and $null -ne $config -and
    $config.PSObject.Properties['gitHubOrganization']) {
    $GitHubOrganization = [string]$config.gitHubOrganization
}

if (-not $PSBoundParameters.ContainsKey('GitHubRepository') -and $null -ne $config -and
    $config.PSObject.Properties['gitHubRepository']) {
    $GitHubRepository = [string]$config.gitHubRepository
}

if (-not $PSBoundParameters.ContainsKey('GitHubEntity') -and $null -ne $config -and
    $config.PSObject.Properties['gitHubEntity']) {
    $GitHubEntity = [string]$config.gitHubEntity
}

if (-not $PSBoundParameters.ContainsKey('GitHubEntityValue') -and $null -ne $config -and
    $config.PSObject.Properties['gitHubEntityValue']) {
    $GitHubEntityValue = [string]$config.gitHubEntityValue
}

if (-not $PSBoundParameters.ContainsKey('CredentialName') -and $null -ne $config -and
    $config.PSObject.Properties['credentialName']) {
    $CredentialName = [string]$config.credentialName
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and $null -ne $config -and
    $config.PSObject.Properties['tenantId']) {
    $TenantId = [string]$config.tenantId
}

if (-not $PSBoundParameters.ContainsKey('GraphScopes') -and $null -ne $config -and
    $config.PSObject.Properties['graphScopes']) {
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
    Write-Host 'AppRegistrationName is required. Specify -AppRegistrationName or set appRegistrationName in the config file.' -ForegroundColor Red
    exit 1
}

if (-not $GitHubOrganization) {
    Write-Host 'GitHubOrganization is required. Specify -GitHubOrganization or set gitHubOrganization in the config file.' -ForegroundColor Red
    exit 1
}

if (-not $GitHubRepository) {
    Write-Host 'GitHubRepository is required. Specify -GitHubRepository or set gitHubRepository in the config file.' -ForegroundColor Red
    exit 1
}

if (-not $GitHubEntity) {
    Write-Host 'GitHubEntity is required. Valid values: branch, tag, environment, pull_request.' -ForegroundColor Red
    exit 1
}

if ($GitHubEntity -ne 'pull_request' -and -not $GitHubEntityValue) {
    Write-Host "GitHubEntityValue is required for entity type '$GitHubEntity'." -ForegroundColor Red
    exit 1
}

# ── Build subject and credential name ─────────────────────────────────────────

$subject = switch ($GitHubEntity) {
    'branch'       { "repo:$GitHubOrganization/$GitHubRepository`:ref:refs/heads/$GitHubEntityValue" }
    'tag'          { "repo:$GitHubOrganization/$GitHubRepository`:ref:refs/tags/$GitHubEntityValue" }
    'environment'  { "repo:$GitHubOrganization/$GitHubRepository`:environment:$GitHubEntityValue" }
    'pull_request' { "repo:$GitHubOrganization/$GitHubRepository`:pull_request" }
}

if (-not $CredentialName) {
    $CredentialName = if ($GitHubEntity -eq 'pull_request') {
        "$GitHubOrganization-$GitHubRepository-pull_request"
    } else {
        "$GitHubOrganization-$GitHubRepository-$GitHubEntity-$GitHubEntityValue"
    }
    # Replace characters invalid for federated credential names
    $CredentialName = $CredentialName -replace '[^a-zA-Z0-9-_.]', '-'
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host '=== Add-FederatedCredentialForGitHub ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config           : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "App Registration : $AppRegistrationName" -ForegroundColor Gray
Write-Host "GitHub repo      : $GitHubOrganization/$GitHubRepository" -ForegroundColor Gray
Write-Host "Entity           : $GitHubEntity$(if ($GitHubEntityValue) { "/$GitHubEntityValue" })" -ForegroundColor Gray
Write-Host "Subject          : $subject" -ForegroundColor Gray
Write-Host "Credential name  : $CredentialName" -ForegroundColor Gray
Write-Host "Graph connect    : $(if ($ConnectGraph) { 'Connect in script' } else { 'Use existing session' })" -ForegroundColor Gray
Write-Host ''

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

    # ── Look up App Registration ───────────────────────────────────────────────

    Write-Host "Looking up App Registration '$AppRegistrationName'..." -ForegroundColor Yellow

    $apps = @(Get-MgApplication -Filter "displayName eq '$AppRegistrationName'" -ErrorAction Stop)

    if ($apps.Count -eq 0) {
        throw "App Registration '$AppRegistrationName' not found."
    }

    if ($apps.Count -gt 1) {
        if (-not $AppId) {
            $list = ($apps | ForEach-Object { "  - $($_.DisplayName)  AppId: $($_.AppId)  ObjectId: $($_.Id)" }) -join "`n"
            throw "Multiple App Registrations found for '$AppRegistrationName'. Specify -AppId to disambiguate:`n$list"
        }
        $app = $apps | Where-Object { $_.AppId -eq $AppId }
        if (-not $app) {
            throw "No App Registration found with name '$AppRegistrationName' and AppId '$AppId'."
        }
    }
    else {
        $app = $apps[0]
    }

    Write-Host "  Found: $($app.DisplayName)  (AppId: $($app.AppId))" -ForegroundColor Green

    # ── Check for existing credential ──────────────────────────────────────────

    Write-Host 'Checking existing federated credentials...' -ForegroundColor Yellow

    $existingCreds = @(Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -ErrorAction Stop)
    $existing = $existingCreds | Where-Object { $_.Name -eq $CredentialName }

    if ($existing) {
        Write-Host "  Federated credential '$CredentialName' already exists." -ForegroundColor Yellow
        Write-Host "  Existing subject : $($existing.Subject)" -ForegroundColor Yellow
        Write-Host "  No changes made." -ForegroundColor Yellow
    }
    else {
        # ── Create federated credential ────────────────────────────────────────

        Write-Host "Creating federated credential '$CredentialName'..." -ForegroundColor Yellow

        $description = "GitHub Actions OIDC for $GitHubOrganization/$GitHubRepository $GitHubEntity$(if ($GitHubEntityValue) { "/$GitHubEntityValue" })"

        $credBody = @{
            Name        = $CredentialName
            Issuer      = 'https://token.actions.githubusercontent.com'
            Subject     = $subject
            Audiences   = @('api://AzureADTokenExchange')
            Description = $description
        }

        $null = New-MgApplicationFederatedIdentityCredential `
            -ApplicationId  $app.Id `
            -BodyParameter  $credBody `
            -ErrorAction    Stop

        Write-Host '  Federated credential created successfully.' -ForegroundColor Green
    }

    # ── Output result ──────────────────────────────────────────────────────────

    $result = [PSCustomObject]@{
        AppName        = $app.DisplayName
        AppId          = $app.AppId
        TenantId       = $context.TenantId
        CredentialName = $CredentialName
        Issuer         = 'https://token.actions.githubusercontent.com'
        Subject        = $subject
        GitHubRepo     = "$GitHubOrganization/$GitHubRepository"
        Entity         = if ($GitHubEntityValue) { "$GitHubEntity/$GitHubEntityValue" } else { $GitHubEntity }
    }

    Write-Host "`nResult:" -ForegroundColor Cyan
    $result | Format-List

    $clipboardText = @(
        "$($result.AppName)",
        "App ID         : $($result.AppId)",
        "Tenant ID      : $($result.TenantId)",
        "Credential     : $($result.CredentialName)",
        "Subject        : $($result.Subject)",
        "GitHub repo    : $($result.GitHubRepo)",
        "Entity         : $($result.Entity)"
    ) -join [Environment]::NewLine

    Set-Clipboard -Value $clipboardText
    Write-Host 'Copied summary to clipboard.' -ForegroundColor Green

    # ── Next steps ─────────────────────────────────────────────────────────────

    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Cyan
    Write-Host '1. Add the following GitHub repository secrets:' -ForegroundColor White
    Write-Host "     AZURE_CLIENT_ID       = $($app.AppId)" -ForegroundColor Yellow
    Write-Host "     AZURE_TENANT_ID       = $($context.TenantId)" -ForegroundColor Yellow
    Write-Host '     AZURE_SUBSCRIPTION_ID = <your-subscription-id>' -ForegroundColor Yellow
    Write-Host '2. Update your GitHub Actions workflow to use OIDC login:' -ForegroundColor White
    Write-Host '     - uses: azure/login@v2' -ForegroundColor Yellow
    Write-Host '       with:' -ForegroundColor Yellow
    Write-Host '         client-id: ${{ secrets.AZURE_CLIENT_ID }}' -ForegroundColor Yellow
    Write-Host '         tenant-id: ${{ secrets.AZURE_TENANT_ID }}' -ForegroundColor Yellow
    Write-Host '         subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}' -ForegroundColor Yellow
    Write-Host '3. Add the following permission to your workflow job:' -ForegroundColor White
    Write-Host '     permissions:' -ForegroundColor Yellow
    Write-Host '       id-token: write' -ForegroundColor Yellow
    Write-Host '       contents: read' -ForegroundColor Yellow
    Write-Host '4. Remove the AZURE_CREDENTIALS secret – no longer needed.' -ForegroundColor White
}
catch {
    Write-Host 'ERROR: Failed to add federated credential.' -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
